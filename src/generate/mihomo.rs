use anyhow::{Context, Result};
use serde_yml::Value;

use crate::config::AppConfig;
use crate::model::ProxyNode;

/// Generate mihomo.yaml by merging the user template with proxy + listener entries.
pub async fn generate_mihomo_config(config: &AppConfig, nodes: &[ProxyNode]) -> Result<()> {
    let template_content = tokio::fs::read_to_string(&config.mihomo.template)
        .await
        .with_context(|| format!("reading mihomo template: {:?}", config.mihomo.template))?;

    let mut root: Value =
        serde_yml::from_str(&template_content).context("parsing mihomo template YAML")?;

    let root_map = root
        .as_mapping_mut()
        .context("mihomo template must be a YAML mapping")?;

    // Build proxies array
    let proxies: Vec<Value> = nodes.iter().map(|n| node_to_mihomo_proxy(n)).collect();
    root_map.insert(
        Value::String("proxies".into()),
        Value::Sequence(proxies),
    );

    // Build listeners array
    let listeners: Vec<Value> = nodes
        .iter()
        .map(|n| node_to_mihomo_listener(n, &config.port.listen_addr))
        .collect();
    root_map.insert(
        Value::String("listeners".into()),
        Value::Sequence(listeners),
    );

    let output = serde_yml::to_string(&root).context("serializing mihomo config")?;

    // Ensure parent directory exists
    if let Some(parent) = config.mihomo.output.parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }
    tokio::fs::write(&config.mihomo.output, output)
        .await
        .with_context(|| format!("writing mihomo config: {:?}", config.mihomo.output))?;

    Ok(())
}

fn node_to_mihomo_proxy(node: &ProxyNode) -> Value {
    let mut map = serde_yml::Mapping::new();
    map.insert(
        Value::String("name".into()),
        Value::String(node.name.clone()),
    );
    map.insert(
        Value::String("type".into()),
        Value::String(node.node_type.to_string()),
    );
    map.insert(
        Value::String("server".into()),
        Value::String(node.server.clone()),
    );
    map.insert(
        Value::String("port".into()),
        Value::Number(serde_yml::Number::from(node.port as u64)),
    );

    // Add all extra params
    for (k, v) in &node.params {
        if let Ok(yaml_val) = json_to_yaml(v) {
            map.insert(Value::String(k.clone()), yaml_val);
        }
    }

    Value::Mapping(map)
}

fn node_to_mihomo_listener(node: &ProxyNode, listen_addr: &str) -> Value {
    let mut map = serde_yml::Mapping::new();
    map.insert(
        Value::String("name".into()),
        Value::String(node.name.clone()),
    );
    map.insert(
        Value::String("type".into()),
        Value::String("socks".into()),
    );
    map.insert(
        Value::String("port".into()),
        Value::Number(serde_yml::Number::from(node.assigned_port as u64)),
    );
    map.insert(
        Value::String("listen".into()),
        Value::String(listen_addr.to_string()),
    );
    map.insert(Value::String("udp".into()), Value::Bool(true));
    map.insert(
        Value::String("proxy".into()),
        Value::String(node.name.clone()),
    );
    Value::Mapping(map)
}

fn json_to_yaml(val: &serde_json::Value) -> Result<Value> {
    match val {
        serde_json::Value::Null => Ok(Value::Null),
        serde_json::Value::Bool(b) => Ok(Value::Bool(*b)),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(Value::Number(serde_yml::Number::from(i)))
            } else if let Some(u) = n.as_u64() {
                Ok(Value::Number(serde_yml::Number::from(u)))
            } else if let Some(f) = n.as_f64() {
                Ok(Value::Number(
                    serde_yml::Number::from(f),
                ))
            } else {
                Ok(Value::Null)
            }
        }
        serde_json::Value::String(s) => Ok(Value::String(s.clone())),
        serde_json::Value::Array(arr) => {
            let seq: Result<Vec<Value>> = arr.iter().map(json_to_yaml).collect();
            Ok(Value::Sequence(seq?))
        }
        serde_json::Value::Object(obj) => {
            let mut map = serde_yml::Mapping::new();
            for (k, v) in obj {
                map.insert(Value::String(k.clone()), json_to_yaml(v)?);
            }
            Ok(Value::Mapping(map))
        }
    }
}
