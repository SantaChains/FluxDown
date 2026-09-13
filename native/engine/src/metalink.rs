//! Metalink（RFC 5854 v4 `.meta4` / RFC 6249 v3 `.metalink`）解析。
//!
//! 把 metalink XML 投影成 [`NewTaskSpec`][crate::download_manager::NewTaskSpec]
//! 的输入：主 URL（最高优先镜像）+ 镜像清单 + 全文件 hash + 大小 hint +
//! 文件名。v3 与 v4 的差异（publisher/identity/version 等）对下载无意义，
//! 两者共有的 `file/name/size/hash/url` 面用一个解析器通吃。
//!
//! v1 语义：多 `<file>` 只取第一个；不支持的 hash 算法跳过（多个 hash 时
//! 取第一个被支持的，sha-256 优先级的实现交给文档顺序——metalink 生成器
//! 惯例把最强 hash 放前面）；`<piece>`（块级 hash）忽略，留给坏块修复 v2。
//!
//! 解析永不 panic：任何结构异常都收敛成 `None` / 空字段，调用方（manager
//! 的 metalink 检测链路）按「不是 metalink」回退普通下载。

use quick_xml::Reader;
use quick_xml::events::Event;

/// metalink 文档大小上限（1 MiB）。
///
/// 真实 metalink 是几十 KB 的纯清单；超限说明这不是 metalink（如误配的
/// 大文件直链），与 `rss::parser::MAX_FEED_BYTES` 同一防御思路。
pub const MAX_METALINK_BYTES: usize = 1024 * 1024;

/// 解析出的单个 `<file>`（v1 只取第一个）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MetalinkFile {
    /// 文件名（`<file name="...">`；空 = 未提供）。
    pub name: String,
    /// 字节数（`<size>`；0 = 未知）。
    pub size: i64,
    /// Checksum spec `algo=hexhash`（与 `tasks.checksum` 同格式，
    /// 喂 `downloader::verify_checksum`）；空 = 文档未提供可支持的 hash。
    pub checksum: String,
    /// 镜像 URL 清单（≥1 才有建镜像任务的意义；首元素 = 最高优先）。
    pub urls: Vec<MirrorUrl>,
}

/// 单个 `<url>` 条目。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MirrorUrl {
    pub url: String,
    /// `priority` 属性（小者优先；缺省 999999 —— 排序时沉底）。
    pub priority: i32,
    /// `location` 属性（ISO 3166 国家码；喂 `CdnNodeInfo.origin` 归因）。
    pub location: String,
}

/// 判定 URL 是否是 metalink 文档地址（建任务入口的快速门）。
///
/// 只认 `.metalink` / `.meta4` 后缀 + http(s) scheme——Content-Type 探测
/// 属于 probe 阶段（响应头到手才能判），不在此处预判。
pub fn is_metalink_url(url: &str) -> bool {
    let lowered = url.trim().to_ascii_lowercase();
    if !(lowered.starts_with("http://") || lowered.starts_with("https://")) {
        return false;
    }
    // 去掉 query/fragment 再看后缀，`?mirror=cn` 之类不破坏判定。
    let path = lowered.split(['?', '#']).next().unwrap_or_default();
    path.ends_with(".metalink") || path.ends_with(".meta4")
}

/// 解析 metalink 字节流。
///
/// 返回 `None` = 不是可识别的 metalink（根元素不是 `metalink`、超大小上限、
/// 或第一个 `<file>` 连一个 URL 都没有）。字段级缺失（无 name / size /
/// hash）不致命——返回带空字段的结果，由调用方按普通下载补全。
pub fn parse_metalink(bytes: &[u8]) -> Option<MetalinkFile> {
    if bytes.is_empty() || bytes.len() > MAX_METALINK_BYTES {
        return None;
    }
    let mut reader = Reader::from_reader(bytes);
    reader.config_mut().trim_text(true);

    let mut buf = Vec::new();
    // 根元素必须是 metalink（namespace 无关判定——v3 文档常省略 xmlns）。
    let mut saw_root = false;
    // 只收集第一个 <file>；闭合后跳过其余内容（文档余量通常极小，
    // 但多 file 的 metalink 仍按此提前止损）。
    let mut file: Option<MetalinkFile> = None;
    let mut in_file = false;
    let mut file_closed = false;
    let mut hash_type = String::new();
    // 当前文本归属元素。
    #[derive(PartialEq, Eq, Clone, Copy)]
    enum TextSlot {
        None,
        Size,
        Hash,
        Url,
    }
    let mut slot = TextSlot::None;
    let mut pending_url: Option<MirrorUrl> = None;

    while let Ok(event) = reader.read_event_into(&mut buf) {
        match event {
            Event::Eof => break,
            Event::Start(e) => match e.local_name().as_ref() {
                b"metalink" => saw_root = true,
                b"file" if saw_root && !file_closed => {
                    in_file = true;
                    file = Some(MetalinkFile {
                        name: attr_str(&e, reader.decoder(), b"name").unwrap_or_default(),
                        ..MetalinkFile::default()
                    });
                }
                b"size" if in_file => slot = TextSlot::Size,
                b"hash" if in_file => {
                    hash_type = attr_str(&e, reader.decoder(), b"type").unwrap_or_default();
                    slot = TextSlot::Hash;
                }
                b"url" if in_file => {
                    slot = TextSlot::Url;
                    pending_url = Some(MirrorUrl {
                        url: String::new(),
                        priority: attr_str(&e, reader.decoder(), b"priority")
                            .and_then(|v| v.trim().parse::<i32>().ok())
                            .unwrap_or(LOWEST_PRIORITY),
                        location: attr_str(&e, reader.decoder(), b"location").unwrap_or_default(),
                    });
                }
                _ => {}
            },
            Event::Text(t) => {
                let Ok(text) = t.decode() else {
                    continue;
                };
                let text = text.trim();
                match (slot, file.as_mut(), pending_url.as_mut()) {
                    (TextSlot::Size, Some(f), _) => {
                        if f.size == 0 {
                            f.size = text.parse::<i64>().unwrap_or(0);
                        }
                    }
                    (TextSlot::Hash, Some(f), _) => {
                        if !text.is_empty()
                            && f.checksum.is_empty()
                            && let Some(algo) = canonical_algo(&hash_type)
                        {
                            f.checksum = format!("{algo}={text}");
                        }
                    }
                    (TextSlot::Url, _, Some(u)) if !text.is_empty() => {
                        u.url = text.to_string();
                    }
                    _ => {}
                }
            }
            Event::End(e) => match e.local_name().as_ref() {
                b"file" if in_file => {
                    in_file = false;
                    file_closed = true;
                }
                b"url" => {
                    if let Some(u) = pending_url.take()
                        && !u.url.is_empty()
                        && let Some(f) = file.as_mut()
                    {
                        f.urls.push(u);
                    }
                    slot = TextSlot::None;
                }
                b"size" | b"hash" => slot = TextSlot::None,
                _ => {}
            },
            _ => {}
        }
        buf.clear();
    }

    if !saw_root {
        return None;
    }
    let mut file = file?;
    if file.urls.is_empty() {
        return None;
    }
    // priority 升序（小者优先），同 priority 保稳定（文档顺序）。
    file.urls.sort_by_key(|u| u.priority);
    Some(file)
}

/// 缺省 priority 沉底值。
const LOWEST_PRIORITY: i32 = 999_999;

/// hash 算法白名单 → canonical 名（与 `downloader::verify_checksum` 的
/// 匹配表逐字对齐）。不支持的算法（如 sha-384）返回 `None` 直接跳过。
fn canonical_algo(raw: &str) -> Option<&'static str> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "sha-256" | "sha256" => Some("sha-256"),
        "sha-512" | "sha512" => Some("sha-512"),
        "sha-1" | "sha1" => Some("sha-1"),
        "md5" => Some("md5"),
        _ => None,
    }
}

/// 提取元素属性（ASCII 字节名，转义解码经 reader 的 decoder；metalink
/// 文档一律 XML 1.0，归一化按 V10 语义——\t\r\n 折叠为空格对
/// name/priority/location 属性无损）。
fn attr_str(
    e: &quick_xml::events::BytesStart<'_>,
    decoder: quick_xml::Decoder,
    name: &[u8],
) -> Option<String> {
    for attr in e.attributes() {
        let Ok(attr) = attr else {
            continue;
        };
        if attr.key.as_ref() == name
            && let Ok(value) =
                attr.decoded_and_normalized_value(quick_xml::XmlVersion::Implicit1_0, decoder)
        {
            return Some(value.into_owned());
        }
    }
    None
}

/// 从 HTTP 响应头解析 `Link: rel=duplicate` 镜像（RFC 6249 Metalink/HTTP）。
///
/// 源站在响应头里宣告同内容的其他副本：
/// `Link: <https://m1/f>; rel=duplicate, <https://m2/f>; rel=duplicate`。
/// probe 本来就要读响应头，顺带解析 = 零额外请求（aria2 同款行为，
/// Ubuntu/Fedora 发行版镜像在用）。
///
/// - 遍历【所有】`Link` 头值（HeaderMap 多值语义），每个值再按条目拆解
///   （RFC 8288：`<URI-Reference>` 尖括号内的逗号不拆）；
/// - 仅取 `rel` 含 `duplicate` 的条目（rel 大小写不敏感、可空格多值、
///   value 可带引号）；
/// - 相对 URL 以 `base_url`（响应最终 URL）解析为绝对；只保留 http(s)；
/// - 去重保序。
///
/// 同 host 过滤不在本函数——镜像池分流处统一做（那里同时持有任务主 URL
/// 与既有镜像清单，见 `downloader::merge_mirror_urls`）。
pub fn discover_duplicate_links(
    headers: &reqwest::header::HeaderMap,
    base_url: &str,
) -> Vec<String> {
    let base = reqwest::Url::parse(base_url).ok();
    let mut out: Vec<String> = Vec::new();
    for value in headers.get_all(reqwest::header::LINK) {
        let Ok(raw) = value.to_str() else {
            continue;
        };
        for (target, params) in parse_link_header(raw) {
            let is_duplicate = params.iter().any(|(k, v)| {
                k == "rel"
                    && v.split_ascii_whitespace()
                        .any(|t| t.eq_ignore_ascii_case("duplicate"))
            });
            if !is_duplicate {
                continue;
            }
            // 相对 URL 以响应最终 URL 解析为绝对；base 缺失时只收绝对 URL。
            let abs = match base.as_ref().and_then(|b| b.join(&target).ok()) {
                Some(u) => u,
                None => match reqwest::Url::parse(&target) {
                    Ok(u) => u,
                    Err(_) => continue,
                },
            };
            if !matches!(abs.scheme(), "http" | "https") {
                continue;
            }
            let s = abs.to_string();
            if !out.contains(&s) {
                out.push(s);
            }
        }
    }
    out
}

/// 拆解单个 `Link` 头值为 `(target, params)` 条目序列（RFC 8288）。
///
/// `<...>` 尖括号内的字符（含逗号）属于 URI-Reference 不拆分；参数段取
/// `>` 之后到下一个条目 `<` 之前的文本，按逗号切分后逐段解析 `k=v`
///（key 归一小写，value 去引号）。结构不完整的条目跳过。
fn parse_link_header(raw: &str) -> Vec<(String, Vec<(String, String)>)> {
    let mut out = Vec::new();
    let mut rest = raw;
    while let Some(open) = rest.find('<') {
        let Some(close_rel) = rest[open..].find('>') else {
            break;
        };
        let target = rest[open + 1..open + close_rel].trim().to_string();
        let after = &rest[open + close_rel + 1..];
        let zone_end = after.find('<').unwrap_or(after.len());
        let params: Vec<(String, String)> = after[..zone_end]
            .split(',')
            .filter_map(|piece| {
                let piece = piece.trim().trim_start_matches(';').trim();
                let (k, v) = piece.split_once('=')?;
                Some((
                    k.trim().to_ascii_lowercase(),
                    v.trim().trim_matches('"').to_string(),
                ))
            })
            .collect();
        if !target.is_empty() {
            out.push((target, params));
        }
        rest = &after[zone_end..];
    }
    out
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::{
        MetalinkFile, MirrorUrl, discover_duplicate_links, is_metalink_url, parse_metalink,
    };

    /// RFC 5854 附录 A 样例的浓缩版（v4 带命名空间）。
    const V4_SAMPLE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<metalink xmlns="urn:ietf:params:xml:ns:metalink">
  <file name="MetalinkReflectivity.mp4">
    <size>1073741824</size>
    <hash type="sha-256">4279e9dc9c3b1a2d7b7ce2e0e6a0e32e2dcb7eebb5f8d3f4f5a6b7c8d9e0f1a2</hash>
    <url priority="1" location="cn">https://mirror.cn/example/MetalinkReflectivity.mp4</url>
    <url priority="2" location="jp">https://mirror.jp/example/MetalinkReflectivity.mp4</url>
    <url>https://mirror.example.org/example/MetalinkReflectivity.mp4</url>
  </file>
</metalink>"#;

    /// v3 风格：无命名空间、URL 带转义、unsupported hash 在前。
    const V3_SAMPLE: &str = r#"<metalink version="3.0">
  <file name="ubuntu.iso">
    <size>52428800</size>
    <hash type="sha-384">unsupported</hash>
    <hash type="sha-256">abc123def456</hash>
    <url priority="2">https://jp.example.com/ubuntu.iso</url>
    <url priority="1" location="cn">https://cn.example.com/ubuntu.iso</url>
  </file>
</metalink>"#;

    #[test]
    fn parses_v4_with_namespace() {
        let f = parse_metalink(V4_SAMPLE.as_bytes()).unwrap();
        assert_eq!(f.name, "MetalinkReflectivity.mp4");
        assert_eq!(f.size, 1_073_741_824);
        assert_eq!(
            f.checksum,
            "sha-256=4279e9dc9c3b1a2d7b7ce2e0e6a0e32e2dcb7eebb5f8d3f4f5a6b7c8d9e0f1a2"
        );
        assert_eq!(f.urls.len(), 3);
        // priority 升序：1(cn) → 2(jp) → 无 priority(沉底)。
        assert_eq!(f.urls[0].priority, 1);
        assert_eq!(f.urls[0].location, "cn");
        assert_eq!(f.urls[1].priority, 2);
        assert_eq!(
            f.urls[2].url,
            "https://mirror.example.org/example/MetalinkReflectivity.mp4"
        );
    }

    #[test]
    fn parses_v3_and_skips_unsupported_hash() {
        let f = parse_metalink(V3_SAMPLE.as_bytes()).unwrap();
        // sha-384 不在白名单，取第二个（sha-256）。
        assert_eq!(f.checksum, "sha-256=abc123def456");
        // priority 乱序输入 → 升序输出。
        assert_eq!(f.urls[0].url, "https://cn.example.com/ubuntu.iso");
        assert_eq!(f.urls[1].url, "https://jp.example.com/ubuntu.iso");
        assert_eq!(f.urls[1].location, "");
    }

    #[test]
    fn takes_first_file_only() {
        let xml = r#"<metalink>
  <file name="a.iso"><url priority="1">https://m1/a.iso</url></file>
  <file name="b.iso"><url priority="1">https://m1/b.iso</url></file>
</metalink>"#;
        let f = parse_metalink(xml.as_bytes()).unwrap();
        assert_eq!(f.name, "a.iso");
        assert_eq!(f.urls.len(), 1);
    }

    #[test]
    fn rejects_non_metalink_root() {
        assert!(parse_metalink(b"<rss><channel></channel></rss>").is_none());
        assert!(parse_metalink(b"<html><body>hi</body></html>").is_none());
    }

    #[test]
    fn rejects_file_without_urls() {
        let xml = r#"<metalink><file name="a.iso"><size>10</size></file></metalink>"#;
        assert!(parse_metalink(xml.as_bytes()).is_none());
    }

    #[test]
    fn empty_and_oversized_input_rejected() {
        assert!(parse_metalink(b"").is_none());
        let big = vec![b'x'; super::MAX_METALINK_BYTES + 1];
        assert!(parse_metalink(&big).is_none());
    }

    #[test]
    fn url_detection() {
        assert!(is_metalink_url("https://example.com/file.meta4"));
        assert!(is_metalink_url("http://example.com/file.metalink?token=1"));
        assert!(is_metalink_url("https://example.com/FILE.METALINK#frag"));
        assert!(!is_metalink_url("https://example.com/file.iso"));
        assert!(!is_metalink_url("https://example.com/file.metalink.exe"));
        // 非 http(s) scheme 不认（ftp/本地路径不适用金属链接抓取链路）。
        assert!(!is_metalink_url("ftp://example.com/file.meta4"));
        assert!(!is_metalink_url("magnet:?xt=urn:btih:abc"));
    }

    #[test]
    fn link_header_duplicate_discovery() {
        use reqwest::header::{HeaderMap, HeaderValue, LINK};

        let mut h = HeaderMap::new();
        h.insert(
            LINK,
            HeaderValue::from_static(
                "<https://m1.example.com/f.iso>; rel=duplicate, <https://m2.example.com/f.iso>; rel=\"duplicate\"",
            ),
        );
        h.append(LINK, HeaderValue::from_static("</f.iso>; rel=duplicate"));
        h.append(
            LINK,
            HeaderValue::from_static("<https://rel.example.com/x>; rel=describedby"),
        );
        h.append(
            LINK,
            HeaderValue::from_static(
                "<https://multi.example.com/f.iso>; rel=\"alternate duplicate\"",
            ),
        );

        let urls = discover_duplicate_links(&h, "https://origin.example.com/dir/page");
        assert_eq!(
            urls,
            vec![
                "https://m1.example.com/f.iso".to_string(),
                "https://m2.example.com/f.iso".to_string(),
                // 相对 URL 以 base 解析为绝对。
                "https://origin.example.com/f.iso".to_string(),
                "https://multi.example.com/f.iso".to_string(),
            ]
        );
    }

    #[test]
    fn link_header_edge_cases() {
        use reqwest::header::{HeaderMap, HeaderValue, LINK};

        // 空 / 非法输入零 panic 零发现。
        assert!(discover_duplicate_links(&HeaderMap::new(), "https://x.example.com/").is_empty());

        let mut h = HeaderMap::new();
        // URL 内含逗号（尖括号保护）；大小写不敏感的 rel；非法 URL 跳过
        //（注：`::::bad` 这类相对片段会被 join 宽松合法化，靠运行时踢除
        // 兑底，此处用真正 parse 失败的未闭合 IPv6 作非法例）。
        h.insert(
            LINK,
            HeaderValue::from_static(
                "<https://comma.example.com/a,b.iso>; REL=DUPLICATE, <http://[::1>; rel=duplicate, <ftp://no.example.com/f>; rel=duplicate",
            ),
        );
        let urls = discover_duplicate_links(&h, "https://x.example.com/");
        assert_eq!(urls, vec!["https://comma.example.com/a,b.iso".to_string()]);

        // base 非法时只收绝对 URL（相对链接跳过，不 panic）。
        let mut h2 = HeaderMap::new();
        h2.insert(LINK, HeaderValue::from_static("</rel.iso>; rel=duplicate"));
        assert!(discover_duplicate_links(&h2, "::::not-a-url").is_empty());
    }

    #[test]
    fn defaults_match() {
        // struct 字段默认值契约（manager 依赖：name/size/checksum 可空）。
        let f = MetalinkFile::default();
        assert!(f.name.is_empty() && f.size == 0 && f.checksum.is_empty());
        let u = MirrorUrl::default();
        assert!(u.url.is_empty());
    }
}
