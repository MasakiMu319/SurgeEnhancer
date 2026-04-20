/// Detected subscription format.
pub enum SubFormat {
    ClashYaml,
    Base64Uri,
    PlainUri,
}

/// Detect subscription body format.
pub fn detect_format(body: &str) -> SubFormat {
    let trimmed = body.trim();

    // Clash YAML: starts with common Clash config keys or contains "proxies:"
    if trimmed.starts_with("proxies:")
        || trimmed.starts_with("port:")
        || trimmed.starts_with("mixed-port:")
        || trimmed.contains("\nproxies:")
    {
        return SubFormat::ClashYaml;
    }

    // Plain URI lines: starts with a known proxy scheme
    if trimmed.starts_with("ss://")
        || trimmed.starts_with("ssr://")
        || trimmed.starts_with("vmess://")
        || trimmed.starts_with("vless://")
        || trimmed.starts_with("trojan://")
        || trimmed.starts_with("hysteria2://")
        || trimmed.starts_with("hy2://")
        || trimmed.starts_with("tuic://")
    {
        return SubFormat::PlainUri;
    }

    // Otherwise assume base64-encoded URI list
    SubFormat::Base64Uri
}
