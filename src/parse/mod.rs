pub mod base64;
pub mod clash;
pub mod detect;

use anyhow::Result;

use crate::model::ProxyNode;

/// Parse raw subscription content into proxy nodes.
/// Auto-detects format (Clash YAML vs base64 URI list).
pub fn parse_subscription(body: &str, group: &str) -> Result<Vec<ProxyNode>> {
    match detect::detect_format(body) {
        detect::SubFormat::ClashYaml => clash::parse_clash_yaml(body, group),
        detect::SubFormat::Base64Uri => base64::parse_base64_uris(body, group),
        detect::SubFormat::PlainUri => base64::parse_uri_lines(body, group),
    }
}
