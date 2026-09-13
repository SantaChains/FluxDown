//! FluxDown 本机服务与客户端共享的传输无关协议类型。
//!
//! 本 crate 只定义 wire 契约；不得依赖下载引擎、网络运行时、数据库或 UI。

use serde::{Deserialize, Serialize};

/// 当前本机服务协议版本。
pub const PROTOCOL_VERSION: u32 = 1;

/// 本机服务在 FluxDown 架构中的职责。
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ServiceRole {
    /// 只管理本地下载能力的常驻核心。
    Daemon,
    /// 向官方客户端提供统一本地入口的常驻代理。
    Agent,
}

/// 客户端建立连接后提交的版本协商信息。
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientHello {
    /// 客户端名称，例如 GPUI、Web 或 CLI。
    pub client_name: String,
    /// 客户端构建版本。
    pub client_version: String,
    /// 客户端支持的本机服务协议版本。
    pub protocol_version: u32,
}

/// 本机服务返回的版本与能力信息。
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceHello {
    /// 服务职责。
    pub role: ServiceRole,
    /// 服务进程名。
    pub service_name: String,
    /// 服务构建版本。
    pub service_version: String,
    /// 服务使用的本机协议版本。
    pub protocol_version: u32,
    /// 服务当前启用的可选能力标识。
    pub capabilities: Vec<String>,
}

impl ServiceHello {
    /// 创建不宣称任何可选能力的服务握手响应。
    #[must_use]
    pub fn new(role: ServiceRole, service_name: &str, service_version: &str) -> Self {
        Self {
            role,
            service_name: service_name.to_owned(),
            service_version: service_version.to_owned(),
            protocol_version: PROTOCOL_VERSION,
            capabilities: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{PROTOCOL_VERSION, ServiceHello, ServiceRole};

    #[test]
    fn service_hello_has_stable_camel_case_wire_shape() -> Result<(), serde_json::Error> {
        let value =
            serde_json::to_value(ServiceHello::new(ServiceRole::Daemon, "fluxdownd", "0.1.0"))?;

        assert_eq!(value["role"], json!("daemon"));
        assert_eq!(value["serviceName"], json!("fluxdownd"));
        assert_eq!(value["serviceVersion"], json!("0.1.0"));
        assert_eq!(value["protocolVersion"], json!(PROTOCOL_VERSION));
        assert_eq!(value["capabilities"], json!([]));
        Ok(())
    }
}
