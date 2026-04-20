use std::collections::HashMap;

use anyhow::{Context, Result};
use serde_json::Value as JsonValue;

use crate::model::{NodeType, ProxyNode};

/// Parse Clash-format YAML subscription body into ProxyNodes.
pub fn parse_clash_yaml(body: &str, group: &str) -> Result<Vec<ProxyNode>> {
    let root: serde_yml::Value =
        serde_yml::from_str(body).context("parsing Clash YAML subscription")?;

    let proxies = root
        .get("proxies")
        .and_then(|v| v.as_sequence())
        .context("no 'proxies' array found in Clash YAML")?;

    let mut nodes = Vec::with_capacity(proxies.len());

    for entry in proxies {
        let map = match entry.as_mapping() {
            Some(m) => m,
            None => continue,
        };

        let name = yaml_str(entry, "name").unwrap_or_default();
        if name.is_empty() {
            continue;
        }

        let type_str = yaml_str(entry, "type").unwrap_or_default();
        let node_type = match type_str.as_str() {
            "ss" => NodeType::Ss,
            "ssr" => NodeType::Ssr,
            "vmess" => NodeType::Vmess,
            "vless" => NodeType::Vless,
            "trojan" => NodeType::Trojan,
            "hysteria2" => NodeType::Hysteria2,
            "tuic" => NodeType::Tuic,
            "anytls" => NodeType::Anytls,
            other => NodeType::Unknown(other.to_string()),
        };

        let server = yaml_str(entry, "server").unwrap_or_default();
        let port = entry
            .get("port")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as u16;

        // Collect all remaining fields as params
        let mut params = HashMap::new();
        for (k, v) in map {
            let key = match k.as_str() {
                Some(s) => s.to_string(),
                None => continue,
            };
            match key.as_str() {
                "name" | "type" | "server" | "port" => continue,
                _ => {
                    if let Ok(json_val) = yaml_to_json(v) {
                        params.insert(key, json_val);
                    }
                }
            }
        }

        nodes.push(ProxyNode {
            name,
            group: group.to_string(),
            node_type,
            server,
            port,
            params,
            assigned_port: 0,
        });
    }

    Ok(nodes)
}

fn yaml_str(val: &serde_yml::Value, key: &str) -> Option<String> {
    val.get(key).and_then(|v| v.as_str()).map(|s| s.to_string())
}

fn yaml_to_json(val: &serde_yml::Value) -> Result<JsonValue> {
    // Round-trip through string for reliable conversion
    let json_str = serde_json::to_string(&yaml_value_to_json(val))?;
    Ok(serde_json::from_str(&json_str)?)
}

fn yaml_value_to_json(val: &serde_yml::Value) -> JsonValue {
    match val {
        serde_yml::Value::Null => JsonValue::Null,
        serde_yml::Value::Bool(b) => JsonValue::Bool(*b),
        serde_yml::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                JsonValue::Number(i.into())
            } else if let Some(u) = n.as_u64() {
                JsonValue::Number(u.into())
            } else if let Some(f) = n.as_f64() {
                serde_json::Number::from_f64(f)
                    .map(JsonValue::Number)
                    .unwrap_or(JsonValue::Null)
            } else {
                JsonValue::Null
            }
        }
        serde_yml::Value::String(s) => JsonValue::String(s.clone()),
        serde_yml::Value::Sequence(seq) => {
            JsonValue::Array(seq.iter().map(yaml_value_to_json).collect())
        }
        serde_yml::Value::Mapping(map) => {
            let mut obj = serde_json::Map::new();
            for (k, v) in map {
                if let Some(key) = k.as_str() {
                    obj.insert(key.to_string(), yaml_value_to_json(v));
                }
            }
            JsonValue::Object(obj)
        }
        serde_yml::Value::Tagged(tagged) => yaml_value_to_json(&tagged.value),
    }
}
