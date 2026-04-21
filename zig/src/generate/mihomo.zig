const std = @import("std");
const config = @import("../config.zig");
const model = @import("../model.zig");

pub fn generateMihomoConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.AppConfig,
    nodes: []const model.ProxyNode,
) !void {
    const template = try std.Io.Dir.cwd().readFileAlloc(io, cfg.mihomo.template, gpa, .unlimited);
    defer gpa.free(template);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(gpa);

    // Build proxies YAML
    var proxies_yaml = std.ArrayList(u8).empty;
    defer proxies_yaml.deinit(gpa);
    try proxies_yaml.appendSlice(gpa, "proxies:\n");
    for (nodes) |n| {
        try proxies_yaml.print(gpa, "  - name: {s}\n", .{n.name});
        try proxies_yaml.print(gpa, "    type: {s}\n", .{n.node_type.toString()});
        try proxies_yaml.print(gpa, "    server: {s}\n", .{n.server});
        try proxies_yaml.print(gpa, "    port: {d}\n", .{n.port});
        var pit = n.params.iterator();
        while (pit.next()) |entry| {
            const k = entry.key_ptr.*;
            if (std.mem.eql(u8, k, "name") or std.mem.eql(u8, k, "type") or
                std.mem.eql(u8, k, "server") or std.mem.eql(u8, k, "port"))
                continue;
            try proxies_yaml.print(gpa, "    {s}: ", .{k});
            try writeYamlValue(&proxies_yaml, gpa, entry.value_ptr.*);
            try proxies_yaml.appendSlice(gpa, "\n");
        }
    }

    // Build listeners YAML
    var listeners_yaml = std.ArrayList(u8).empty;
    defer listeners_yaml.deinit(gpa);
    try listeners_yaml.appendSlice(gpa, "listeners:\n");
    for (nodes) |n| {
        try listeners_yaml.print(gpa, "  - name: {s}\n", .{n.name});
        try listeners_yaml.appendSlice(gpa, "    type: socks\n");
        try listeners_yaml.print(gpa, "    port: {d}\n", .{n.assigned_port});
        try listeners_yaml.print(gpa, "    listen: {s}\n", .{cfg.port.listen_addr});
        try listeners_yaml.appendSlice(gpa, "    udp: true\n");
        try listeners_yaml.print(gpa, "    proxy: {s}\n", .{n.name});
    }

    // Merge into template by text replacement
    try mergeYamlBlocks(gpa, template, proxies_yaml.items, listeners_yaml.items, &output);

    // Ensure parent dir exists
    const output_path = cfg.mihomo.output;
    if (std.mem.lastIndexOf(u8, output_path, "/")) |slash| {
        const dir = output_path[0..slash];
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = output.items });
}

fn writeYamlValue(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .string => |s| try list.print(gpa, "\"{s}\"", .{s}),
        .integer => |i| try list.print(gpa, "{d}", .{i}),
        .float => |f| try list.print(gpa, "{d}", .{f}),
        .bool => |b| try list.print(gpa, "{}", .{b}),
        .null => try list.appendSlice(gpa, "null"),
        .array => |arr| {
            try list.appendSlice(gpa, "[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try list.appendSlice(gpa, ", ");
                try writeYamlValue(list, gpa, item);
            }
            try list.appendSlice(gpa, "]");
        },
        .object => |obj| {
            try list.appendSlice(gpa, "{");
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try list.appendSlice(gpa, ", ");
                first = false;
                try list.print(gpa, "{s}: ", .{entry.key_ptr.*});
                try writeYamlValue(list, gpa, entry.value_ptr.*);
            }
            try list.appendSlice(gpa, "}");
        },
        else => try list.appendSlice(gpa, "null"),
    }
}

fn mergeYamlBlocks(
    gpa: std.mem.Allocator,
    template: []const u8,
    proxies_block: []const u8,
    listeners_block: []const u8,
    output: *std.ArrayList(u8),
) !void {
    // Split template lines
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, template, '\n');
    while (it.next()) |line| {
        try lines.append(gpa, line);
    }

    // Find proxies: and listeners: positions
    var proxies_idx: ?usize = null;
    var listeners_idx: ?usize = null;
    for (lines.items, 0..) |line, i| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "proxies:") or std.mem.startsWith(u8, trimmed, "proxies:")) {
            proxies_idx = i;
        }
        if (std.mem.eql(u8, trimmed, "listeners:") or std.mem.startsWith(u8, trimmed, "listeners:")) {
            listeners_idx = i;
        }
    }

    // Sort indices
    const first_idx = if (proxies_idx != null and listeners_idx != null)
        @min(proxies_idx.?, listeners_idx.?)
    else if (proxies_idx != null)
        proxies_idx.?
    else if (listeners_idx != null)
        listeners_idx.?
    else
        null;

    if (first_idx) |fi| {
        // Copy lines before first block
        for (lines.items[0..fi]) |line| {
            try output.appendSlice(gpa, line);
            try output.appendSlice(gpa, "\n");
        }
        // Insert new blocks
        try output.appendSlice(gpa, proxies_block);
        try output.appendSlice(gpa, "\n");
        try output.appendSlice(gpa, listeners_block);
        try output.appendSlice(gpa, "\n");
    } else {
        // No existing blocks, append everything + new blocks
        try output.appendSlice(gpa, template);
        if (!std.mem.endsWith(u8, template, "\n")) try output.appendSlice(gpa, "\n");
        try output.appendSlice(gpa, "\n");
        try output.appendSlice(gpa, proxies_block);
        try output.appendSlice(gpa, "\n");
        try output.appendSlice(gpa, listeners_block);
        try output.appendSlice(gpa, "\n");
    }
}
