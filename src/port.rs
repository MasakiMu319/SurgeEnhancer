use std::collections::HashMap;

use crate::model::ProxyNode;

/// Assigns deterministic ports starting from `range_start`, sequentially
/// across all groups in order. Returns the updated port_map.
pub fn assign_ports(
    nodes: &mut [ProxyNode],
    range_start: u16,
    existing_map: &HashMap<String, u16>,
) -> HashMap<String, u16> {
    let mut port_map = HashMap::new();
    let mut next_port = range_start;

    // First pass: reuse existing ports for nodes that already have one
    for node in nodes.iter() {
        if let Some(&port) = existing_map.get(&node.name) {
            port_map.insert(node.name.clone(), port);
            if port >= next_port {
                next_port = port + 1;
            }
        }
    }

    // Second pass: assign new ports to nodes without one
    for node in nodes.iter_mut() {
        if !port_map.contains_key(&node.name) {
            while port_map.values().any(|&p| p == next_port) {
                next_port += 1;
            }
            port_map.insert(node.name.clone(), next_port);
            node.assigned_port = next_port;
            next_port += 1;
        } else {
            node.assigned_port = port_map[&node.name];
        }
    }

    port_map
}
