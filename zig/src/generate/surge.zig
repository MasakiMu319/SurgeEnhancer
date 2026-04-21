const std = @import("std");
const config = @import("../config.zig");
const model = @import("../model.zig");

pub fn generateSurgeProxyList(gpa: std.mem.Allocator, nodes: []const model.ProxyNode, listen_addr: []const u8) ![]const u8 {
    var lines = std.ArrayList(u8).empty;
    defer lines.deinit(gpa);
    try lines.ensureTotalCapacity(gpa, nodes.len * 64);
    for (nodes) |n| {
        try lines.print(gpa, "{s} = socks5, {s}, {d}\n", .{ n.name, listen_addr, n.assigned_port });
    }
    return lines.toOwnedSlice(gpa);
}

pub fn generateSurgeConfig(
    gpa: std.mem.Allocator,
    cfg: config.AppConfig,
    groups: *const std.array_hash_map.String([]model.ProxyNode),
) ![]const u8 {
    const listen_addr = cfg.port.listen_addr;
    const server_listen = cfg.server.listen;

    var lines = std.ArrayList(u8).empty;
    defer lines.deinit(gpa);
    var total_nodes: usize = 0;
    var cit = groups.iterator();
    while (cit.next()) |entry| total_nodes += entry.value_ptr.*.len;
    try lines.ensureTotalCapacity(gpa, total_nodes * 64 + 256);

    try lines.appendSlice(gpa, "[Proxy]\n");
    var git = groups.iterator();
    while (git.next()) |entry| {
        for (entry.value_ptr.*) |n| {
            try lines.print(gpa, "{s} = socks5, {s}, {d}\n", .{ n.name, listen_addr, n.assigned_port });
        }
    }

    try lines.appendSlice(gpa, "\n[Proxy Group]\n");
    git = groups.iterator();
    while (git.next()) |entry| {
        const name = entry.key_ptr.*;
        try lines.print(gpa, "{s} = select, policy-path=http://{s}/surge/group/{s}\n", .{ name, server_listen, name });
    }

    if (groups.count() > 1) {
        try lines.appendSlice(gpa, "AllNodes = select, ");
        var first = true;
        git = groups.iterator();
        while (git.next()) |entry| {
            if (!first) try lines.appendSlice(gpa, ", ");
            first = false;
            try lines.appendSlice(gpa, entry.key_ptr.*);
        }
        try lines.appendSlice(gpa, "\n");
    }

    return lines.toOwnedSlice(gpa);
}
