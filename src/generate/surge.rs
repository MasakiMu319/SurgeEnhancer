use crate::config::AppConfig;
use crate::model::ProxyNode;

/// Generate Surge [Proxy] lines for a list of nodes.
pub fn generate_surge_proxy_list(nodes: &[ProxyNode], listen_addr: &str) -> String {
    nodes
        .iter()
        .map(|n| format!("{} = socks5, {}, {}", n.name, listen_addr, n.assigned_port))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Generate a full Surge config snippet with [Proxy] and [Proxy Group] sections.
pub fn generate_surge_config(
    config: &AppConfig,
    groups: &indexmap::IndexMap<String, Vec<ProxyNode>>,
) -> String {
    let listen_addr = &config.port.listen_addr;
    let server_listen = &config.server.listen;

    let mut lines = Vec::new();
    lines.push("[Proxy]".to_string());

    for nodes in groups.values() {
        for n in nodes {
            lines.push(format!(
                "{} = socks5, {}, {}",
                n.name, listen_addr, n.assigned_port
            ));
        }
    }

    lines.push(String::new());
    lines.push("[Proxy Group]".to_string());

    for (name, _) in groups {
        lines.push(format!(
            "{name} = select, policy-path=http://{server_listen}/surge/group/{name}"
        ));
    }

    // AllNodes group referencing all sub-groups
    if groups.len() > 1 {
        let group_names: Vec<_> = groups.keys().cloned().collect();
        lines.push(format!("AllNodes = select, {}", group_names.join(", ")));
    }

    lines.join("\n")
}
