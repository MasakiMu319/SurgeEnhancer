use std::collections::HashMap;

use crate::model::ProxyNode;

/// Assigns deterministic ports to nodes, avoiding collisions with
/// ports already in the global `existing_map` (which includes all groups).
/// Returns only the new/updated entries for this batch of nodes.
pub fn assign_ports(
    nodes: &mut [ProxyNode],
    range_start: u16,
    existing_map: &HashMap<String, u16>,
) -> HashMap<String, u16> {
    let mut new_entries = HashMap::new();

    // Collect all occupied ports (from other groups that are already assigned)
    let occupied: std::collections::HashSet<u16> = existing_map.values().copied().collect();
    let mut next_port = range_start;

    for node in nodes.iter_mut() {
        // Reuse existing port if this node already has one
        if let Some(&port) = existing_map.get(&node.name) {
            node.assigned_port = port;
            new_entries.insert(node.name.clone(), port);
            continue;
        }

        // Find the next available port not in occupied set or already assigned
        while occupied.contains(&next_port) || new_entries.values().any(|&p| p == next_port) {
            next_port += 1;
        }

        node.assigned_port = next_port;
        new_entries.insert(node.name.clone(), next_port);
        next_port += 1;
    }

    new_entries
}
