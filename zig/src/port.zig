const std = @import("std");
const model = @import("model.zig");

pub fn assignPorts(
    gpa: std.mem.Allocator,
    nodes: []model.ProxyNode,
    range_start: u16,
    existing_map: *std.StringHashMap(u16),
) !std.StringHashMap(u16) {
    var new_entries = std.StringHashMap(u16).init(gpa);
    errdefer new_entries.deinit();

    // Collect occupied ports
    var occupied = std.AutoHashMap(u16, void).init(gpa);
    defer occupied.deinit();
    var it = existing_map.valueIterator();
    while (it.next()) |p| {
        try occupied.put(p.*, {});
    }

    var next_port: u16 = range_start;
    for (nodes) |*node| {
        if (existing_map.get(node.name)) |port| {
            node.assigned_port = port;
            try new_entries.put(try gpa.dupe(u8, node.name), port);
            continue;
        }

        while (occupied.contains(next_port)) {
            next_port +|= 1;
            if (next_port == 0) return error.PortExhausted;
        }

        node.assigned_port = next_port;
        try new_entries.put(try gpa.dupe(u8, node.name), next_port);
        try occupied.put(next_port, {});
        next_port +|= 1;
    }

    return new_entries;
}
