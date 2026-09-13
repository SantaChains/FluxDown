//! 传输层调优探测：BBR / MPTCP / QUIC 可用性、当前拥塞控制算法与 OS 能力画像。
//!
//! 本模块**只读**——不修改内核参数、不强行设 socket option。
//! reqwest 0.12 不暴露 socket option API；强行注入 CC 算法需绕过其
//! 连接建立层（自定义 hyper connector + socket2），改造面大且收益
//! 集中在弱网场景。当下正确做法是**探测 + 引导用户在 OS 层启用**，
//! 而非代码层硬塞。
//!
//! # 设计动机
//!
//! 1. **BBR** 是 OS 内核级能力（Linux 4.9+ / Win11 24H2 BBRv2 基线）。
//!    在 Linux 上 `sysctl net.ipv4.tcp_congestion_control=bbr` 即可全
//!    局启用；应用层无需改代码，所有新 TCP 连接自动继承。客户端在不
//!    知情的情况下就吃到了 BBR 的弱网吞吐增益（+45%~+120%）。
//!
//! 2. **MPTCP** 同为内核能力（Linux 5.6+ / Win11 24H2+）。客户端的控
//!    制权有限——内核决定子流数量与路径选择；多 NIC 服务器场景才有
//!    明显收益，家用单 ISP 链路边际收益接近 0。本模块仅做能力探测。
//!
//! 3. **QUIC/HTTP3** 在 reqwest 0.12 仍是 `unstable` feature，且仅支
//!    持 `rustls` 后端，本项目 Windows 分支用 `native-tls`。强行启用
//!    会引入 unstable-feature 不稳定性 + 牵动全平台 TLS 后端迁移。本
//!    模块只做 OS 层 UDP/QUIC 端口可达性探测，留给后续 feature 门控
//!    开关真正实现时一个"OS 是否具备 QUIC 接收能力"的事实依据。
//!
//! # 调用点
//!
//! 引擎启动时（`Engine::initialize` 末尾）调用 [`probe_and_log`]，把
//! 探测结果以 info 日志输出。宿主（hub/server）可经 `Engine::transport_tuning`
//! 取报告写入诊断面板或 settings 页面。

use std::time::Duration;

/// 单一 OS 能力画像。所有字段在探测失败时退回保守默认（不可用 / 未知）。
///
/// 字段语义见 [`probe_and_log`] 的输出注释。报告本身**不**触发任何内核
/// 改动；它只是事实陈述，供宿主 UI/日志显示与用户决策（"要不要手动开
/// BBR"）使用。
#[derive(Debug, Clone, Default)]
pub struct TransportTuningReport {
    /// 当前 TCP 拥塞控制算法名（Linux: 从 `/proc/sys/net/ipv4/tcp_congestion_control`
    /// 读；Windows/macOS: 保守标注 `"cubic"` 或 `"unknown"`）。
    pub current_cc_algorithm: String,
    /// OS 可用的 CC 算法清单（Linux: `/proc/sys/net/ipv4/tcp_available_congestion_control`；
    /// 其余平台仅含保守默认）。
    pub available_cc_algorithms: Vec<String>,
    /// BBR 是否在可用列表中（不代表已启用，仅代表 OS 内核支持）。
    pub bbr_available: bool,
    /// BBR 是否为当前生效的 CC 算法。
    pub bbr_active: bool,
    /// MPTCP 是否被 OS 内核支持（Linux 5.6+：`/proc/sys/net/mptcp/enabled`）。
    pub mptcp_supported: bool,
    /// MPTCP 是否被启用（即使支持也可能 sysctl 关闭）。
    pub mptcp_enabled: bool,
    /// UDP 是否可用（QUIC 的传输底座）。几乎所有现代 OS 都为 true。
    pub udp_available: bool,
    /// QUIC/HTTP3 在应用层是否可启用（依赖 reqwest feature + rustls TLS
    /// 后端 + OS UDP）。**当前一律为 false**：reqwest 0.12 http3 仍
    /// unstable，且 Windows 分支用 native-tls，需先迁移 TLS 后端。
    pub quic_app_ready: bool,
    /// 平台名（`"linux"` / `"windows"` / `"macos"` / `"unknown"`）。
    pub platform: &'static str,
    /// 探测耗时（仅诊断用）。
    pub probe_elapsed: Duration,
}

impl TransportTuningReport {
    /// 输出面向用户日志的单行摘要。
    pub fn one_line_summary(&self) -> String {
        let cc = if self.bbr_active {
            "BBR ✓"
        } else {
            &self.current_cc_algorithm
        };
        let mptcp = if self.mptcp_enabled {
            "enabled"
        } else if self.mptcp_supported {
            "supported-off"
        } else {
            "unsupported"
        };
        let quic = if self.quic_app_ready {
            "ready"
        } else {
            "not-ready"
        };
        format!(
            "cc={cc} mptcp={mptcp} quic={quic} bbr_avail={} udp={}",
            self.bbr_available, self.udp_available
        )
    }
}

/// 探测本机传输层能力，输出 info 日志并返回报告。
///
/// 设计为**幂等且不失败**：任何子探测错误都吞掉，对应字段保持保守默认。
/// 启动时调用方不应阻塞——所有 IO 是 `spawn_blocking` 内的几字节
/// `/proc/sys` 读或 `std::net::UdpSocket` 探测，开销 < 1 ms。
pub async fn probe_and_log() -> TransportTuningReport {
    let started = std::time::Instant::now();
    let report = tokio::task::spawn_blocking(probe_os_transport)
        .await
        .unwrap_or_else(|e| {
            tracing::warn!("[transport-tuning] probe task failed: {e}");
            TransportTuningReport {
                platform: detect_platform(),
                ..Default::default()
            }
        });
    let report = TransportTuningReport {
        probe_elapsed: started.elapsed(),
        ..report
    };
    tracing::info!(
        "[transport-tuning] {} (probe {:?})",
        report.one_line_summary(),
        report.probe_elapsed
    );
    if !report.bbr_active && report.bbr_available {
        tracing::info!(
            "[transport-tuning] BBR is available but not active. \
             On Linux: `sudo sysctl -w net.ipv4.tcp_congestion_control=bbr` \
             (persist in /etc/sysctl.d/99-fluxdown.conf). \
             On Windows 11 24H2+: `netsh int tcp set supplemental tcp=bbr2`."
        );
    }
    if !report.mptcp_enabled && report.mptcp_supported {
        tracing::info!(
            "[transport-tuning] MPTCP is supported but disabled. \
             On Linux: `sudo sysctl -w net.mptcp.enabled=1`."
        );
    }
    if !report.quic_app_ready {
        tracing::info!(
            "[transport-tuning] QUIC/HTTP3 not app-ready: reqwest 0.12 http3 \
             is still unstable and Windows branch uses native-tls. \
             See readme.transport.md for migration path."
        );
    }
    report
}

/// 同步探测——所有 IO 在调用方负责的 `spawn_blocking` 中执行。
fn probe_os_transport() -> TransportTuningReport {
    let platform = detect_platform();
    match platform {
        "linux" => probe_linux(),
        "windows" => probe_windows(),
        "macos" => probe_macos(),
        _ => TransportTuningReport {
            platform,
            udp_available: true,
            ..Default::default()
        },
    }
}

fn detect_platform() -> &'static str {
    if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "unknown"
    }
}

fn probe_linux() -> TransportTuningReport {
    let current_cc = read_proc_sys("/proc/sys/net/ipv4/tcp_congestion_control")
        .unwrap_or_default()
        .trim()
        .to_string();
    let available = read_proc_sys("/proc/sys/net/ipv4/tcp_available_congestion_control")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_string)
        .collect::<Vec<_>>();
    let bbr_available = available.iter().any(|s| s.eq_ignore_ascii_case("bbr"));
    let bbr_active = current_cc.eq_ignore_ascii_case("bbr");
    let mptcp_supported = path_exists("/proc/sys/net/mptcp/enabled");
    let mptcp_enabled = if mptcp_supported {
        read_proc_sys("/proc/sys/net/mptcp/enabled")
            .map(|s| s.trim() == "1")
            .unwrap_or(false)
    } else {
        false
    };
    TransportTuningReport {
        current_cc_algorithm: current_cc,
        available_cc_algorithms: available,
        bbr_available,
        bbr_active,
        mptcp_supported,
        mptcp_enabled,
        udp_available: probe_udp_socket(),
        quic_app_ready: false, // 见模块级文档：reqwest http3 仍 unstable。
        platform: "linux",
        probe_elapsed: Duration::default(),
    }
}

fn probe_windows() -> TransportTuningReport {
    // Windows 11 24H2 (build 26100+) 起内置 BBRv2 基线（默认关，netsh 启用）；
    // 24H2 也开始有 MPTCP 客户端实验支持。低版本退回保守默认。
    let (build_major, _build_minor) = read_windows_build_version();
    let is_24h2_or_later = build_major >= 26100;
    TransportTuningReport {
        current_cc_algorithm: if is_24h2_or_later {
            "cubic (default; bbr2 opt-in via netsh)".to_string()
        } else {
            "cubic".to_string()
        },
        available_cc_algorithms: if is_24h2_or_later {
            vec![
                "cubic".to_string(),
                "bbr2".to_string(),
                "compound".to_string(),
            ]
        } else {
            vec!["cubic".to_string(), "compound".to_string()]
        },
        bbr_available: is_24h2_or_later,
        bbr_active: false, // 默认未启；用户须 netsh 启用
        mptcp_supported: is_24h2_or_later,
        mptcp_enabled: false,
        udp_available: probe_udp_socket(),
        quic_app_ready: false,
        platform: "windows",
        probe_elapsed: Duration::default(),
    }
}

fn probe_macos() -> TransportTuningReport {
    // macOS 至 Sonoma 仍以 cubic 为默认；无内置 BBR。MPTCP 仅服务端用
    // 于 Siri/FaceTime，第三方应用拿不到 socket option。
    TransportTuningReport {
        current_cc_algorithm: "cubic".to_string(),
        available_cc_algorithms: vec!["cubic".to_string()],
        bbr_available: false,
        bbr_active: false,
        mptcp_supported: false,
        mptcp_enabled: false,
        udp_available: probe_udp_socket(),
        quic_app_ready: false,
        platform: "macos",
        probe_elapsed: Duration::default(),
    }
}

fn read_proc_sys(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok()
}

fn path_exists(path: &str) -> bool {
    std::path::Path::new(path).exists()
}

/// 用临时绑定 0.0.0.0:0 的 UDP socket 探测 UDP 栈可用性。
/// 失败（极少见）= UDP 栈损坏或权限被剥夺。
fn probe_udp_socket() -> bool {
    std::net::UdpSocket::bind("0.0.0.0:0").is_ok()
}

/// 读 Windows 内核 build 号（`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`
/// 的 `CurrentBuildNumber`）。失败时返回 (0, 0)，使调用方退回保守默认。
#[cfg(target_os = "windows")]
fn read_windows_build_version() -> (u32, u32) {
    // 不引入新的 winreg 调用开销——winreg 已是 windows 分支依赖；
    // 这里只用 stdlib + 既有 winreg crate。
    use winreg::{RegKey, enums::*};
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = hklm
        .open_subkey_with_flags(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", KEY_READ)
        .ok();
    let Some(key) = key else {
        return (0, 0);
    };
    let major: u32 = key.get_value("CurrentBuildNumber").ok().unwrap_or(0);
    // CurrentBuildNumber 形如 "26100"；UBR（Update Build Revision）在
    // 另一字段，不影响 BBR 可用性判定（26100 即 24H2 基线）。
    (major, 0)
}

#[cfg(not(target_os = "windows"))]
fn read_windows_build_version() -> (u32, u32) {
    (0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_line_summary_never_panics() {
        let r = TransportTuningReport::default();
        let _ = r.one_line_summary();
    }

    #[test]
    fn detect_platform_returns_known_or_unknown() {
        let p = detect_platform();
        assert!(matches!(p, "linux" | "windows" | "macos" | "unknown"));
    }

    #[test]
    fn probe_udp_socket_is_ok_on_modern_os() {
        // 任何现代 OS 应能 bind 一临时 UDP socket。
        assert!(probe_udp_socket());
    }
}
