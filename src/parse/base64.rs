use std::collections::HashMap;

use anyhow::{Context, Result};
use base64::Engine;

use crate::model::{NodeType, ProxyNode};

/// Decode base64 body then parse URI lines.
pub fn parse_base64_uris(body: &str, group: &str) -> Result<Vec<ProxyNode>> {
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(body.trim())
        .or_else(|_| {
            base64::engine::general_purpose::STANDARD_NO_PAD.decode(body.trim())
        })
        .or_else(|_| {
            base64::engine::general_purpose::URL_SAFE.decode(body.trim())
        })
        .or_else(|_| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(body.trim())
        })
        .context("base64 decode subscription body")?;

    let text = String::from_utf8_lossy(&decoded);
    parse_uri_lines(&text, group)
}

/// Parse newline-separated proxy URIs.
pub fn parse_uri_lines(text: &str, group: &str) -> Result<Vec<ProxyNode>> {
    let mut nodes = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        match parse_single_uri(line, group) {
            Ok(node) => nodes.push(node),
            Err(e) => {
                tracing::warn!(uri = line, error = %e, "skipping unparseable proxy URI");
            }
        }
    }
    Ok(nodes)
}

fn parse_single_uri(uri: &str, group: &str) -> Result<ProxyNode> {
    if let Some(rest) = uri.strip_prefix("ss://") {
        return parse_ss(rest, group);
    }
    if let Some(rest) = uri.strip_prefix("vmess://") {
        return parse_vmess(rest, group);
    }
    if let Some(rest) = uri.strip_prefix("trojan://") {
        return parse_trojan(rest, group);
    }
    if let Some(rest) = uri.strip_prefix("vless://") {
        return parse_vless(rest, group);
    }
    if uri.starts_with("hysteria2://") || uri.starts_with("hy2://") {
        let rest = uri.split_once("://").unwrap().1;
        return parse_hysteria2(rest, group);
    }
    anyhow::bail!("unsupported proxy URI scheme: {uri}");
}

/// SS URI: ss://base64(method:password)@host:port#name
/// or:    ss://base64(method:password@host:port)#name
fn parse_ss(rest: &str, group: &str) -> Result<ProxyNode> {
    let (main, name) = split_fragment(rest);

    // Try SIP002 format: base64(userinfo)@host:port
    if let Some((userinfo_b64, host_port)) = main.split_once('@') {
        let userinfo = b64_decode(userinfo_b64)?;
        let (method, password) = userinfo
            .split_once(':')
            .context("ss userinfo missing ':'")?;
        let (host, port) = parse_host_port(host_port)?;

        let mut params = HashMap::new();
        params.insert("cipher".into(), serde_json::Value::String(method.to_string()));
        params.insert(
            "password".into(),
            serde_json::Value::String(password.to_string()),
        );

        return Ok(ProxyNode {
            name: percent_decode(&name),
            group: group.to_string(),
            node_type: NodeType::Ss,
            server: host.to_string(),
            port,
            params,
            assigned_port: 0,
        });
    }

    // Legacy format: base64(method:password@host:port)
    let decoded = b64_decode(main)?;
    let (userinfo, host_port) = decoded
        .rsplit_once('@')
        .context("ss legacy format missing '@'")?;
    let (method, password) = userinfo.split_once(':').context("ss missing method:pass")?;
    let (host, port) = parse_host_port(host_port)?;

    let mut params = HashMap::new();
    params.insert("cipher".into(), serde_json::Value::String(method.to_string()));
    params.insert(
        "password".into(),
        serde_json::Value::String(password.to_string()),
    );

    Ok(ProxyNode {
        name: percent_decode(&name),
        group: group.to_string(),
        node_type: NodeType::Ss,
        server: host.to_string(),
        port,
        params,
        assigned_port: 0,
    })
}

/// VMess URI: vmess://base64(json)
fn parse_vmess(rest: &str, group: &str) -> Result<ProxyNode> {
    let decoded = b64_decode(rest.split('#').next().unwrap_or(rest))?;
    let json: serde_json::Value =
        serde_json::from_str(&decoded).context("vmess JSON decode")?;

    let name = json_str(&json, "ps")
        .or_else(|| json_str(&json, "remarks"))
        .unwrap_or_else(|| "unnamed".to_string());
    let server = json_str(&json, "add").unwrap_or_default();
    let port = json["port"]
        .as_str()
        .and_then(|s| s.parse().ok())
        .or_else(|| json["port"].as_u64().map(|n| n as u16))
        .unwrap_or(0);

    let mut params = HashMap::new();
    for key in &["id", "aid", "net", "type", "host", "path", "tls", "sni", "alpn"] {
        if let Some(v) = json.get(*key) {
            if !v.is_null() {
                params.insert(key.to_string(), v.clone());
            }
        }
    }

    Ok(ProxyNode {
        name,
        group: group.to_string(),
        node_type: NodeType::Vmess,
        server,
        port,
        params,
        assigned_port: 0,
    })
}

/// Trojan URI: trojan://password@host:port?params#name
fn parse_trojan(rest: &str, group: &str) -> Result<ProxyNode> {
    let (main, name) = split_fragment(rest);
    let (password, after_at) = main.split_once('@').context("trojan missing '@'")?;
    let (host_port, query) = split_query(after_at);
    let (host, port) = parse_host_port(host_port)?;

    let mut params = parse_query_params(query);
    params.insert(
        "password".into(),
        serde_json::Value::String(percent_decode(password)),
    );

    Ok(ProxyNode {
        name: percent_decode(&name),
        group: group.to_string(),
        node_type: NodeType::Trojan,
        server: host.to_string(),
        port,
        params,
        assigned_port: 0,
    })
}

/// VLESS URI: vless://uuid@host:port?params#name
fn parse_vless(rest: &str, group: &str) -> Result<ProxyNode> {
    let (main, name) = split_fragment(rest);
    let (uuid, after_at) = main.split_once('@').context("vless missing '@'")?;
    let (host_port, query) = split_query(after_at);
    let (host, port) = parse_host_port(host_port)?;

    let mut params = parse_query_params(query);
    params.insert("uuid".into(), serde_json::Value::String(uuid.to_string()));

    Ok(ProxyNode {
        name: percent_decode(&name),
        group: group.to_string(),
        node_type: NodeType::Vless,
        server: host.to_string(),
        port,
        params,
        assigned_port: 0,
    })
}

/// Hysteria2 URI: hysteria2://auth@host:port?params#name
fn parse_hysteria2(rest: &str, group: &str) -> Result<ProxyNode> {
    let (main, name) = split_fragment(rest);
    let (auth, after_at) = main.split_once('@').context("hysteria2 missing '@'")?;
    let (host_port, query) = split_query(after_at);
    let (host, port) = parse_host_port(host_port)?;

    let mut params = parse_query_params(query);
    params.insert(
        "password".into(),
        serde_json::Value::String(percent_decode(auth)),
    );

    Ok(ProxyNode {
        name: percent_decode(&name),
        group: group.to_string(),
        node_type: NodeType::Hysteria2,
        server: host.to_string(),
        port,
        params,
        assigned_port: 0,
    })
}

// --- Helpers ---

fn split_fragment(s: &str) -> (&str, String) {
    match s.split_once('#') {
        Some((main, frag)) => (main, percent_decode(frag)),
        None => (s, "unnamed".to_string()),
    }
}

fn split_query(s: &str) -> (&str, &str) {
    match s.split_once('?') {
        Some((host_port, query)) => (host_port, query),
        None => (s, ""),
    }
}

fn parse_host_port(s: &str) -> Result<(&str, u16)> {
    // Handle [ipv6]:port
    if let Some(rest) = s.strip_prefix('[') {
        let (ipv6, port_str) = rest.split_once("]:").context("malformed ipv6 host:port")?;
        let port: u16 = port_str.parse().context("invalid port")?;
        return Ok((ipv6, port));
    }
    let (host, port_str) = s.rsplit_once(':').context("missing ':' in host:port")?;
    let port: u16 = port_str.parse().context("invalid port")?;
    Ok((host, port))
}

fn parse_query_params(query: &str) -> HashMap<String, serde_json::Value> {
    let mut params = HashMap::new();
    if query.is_empty() {
        return params;
    }
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            params.insert(
                k.to_string(),
                serde_json::Value::String(percent_decode(v)),
            );
        }
    }
    params
}

fn percent_decode(s: &str) -> String {
    percent_encoding::percent_decode_str(s)
        .decode_utf8_lossy()
        .to_string()
}

fn b64_decode(s: &str) -> Result<String> {
    let s = s.trim();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(s)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(s))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(s))
        .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s))
        .context("base64 decode failed")?;
    Ok(String::from_utf8_lossy(&bytes).to_string())
}

fn json_str(val: &serde_json::Value, key: &str) -> Option<String> {
    val.get(key)?.as_str().map(|s| s.to_string())
}
