const std = @import("std");
const model = @import("../model.zig");
const libyaml = @import("../libyaml.zig");

pub fn parseClashYaml(gpa: std.mem.Allocator, body: []const u8, group: []const u8) ![]model.ProxyNode {
    var parser = try libyaml.Parser.init();
    defer parser.deinit();
    parser.setInputString(body);

    // Skip to proxies sequence
    try libyaml.findProxiesSequence(&parser);

    var nodes = std.ArrayList(model.ProxyNode).empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(gpa);
        nodes.deinit(gpa);
    }

    // Read each proxy mapping in the sequence
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .sequence_end) {
            ev.deinit();
            break;
        }
        if (et == .mapping_start) {
            ev.deinit();
            const node = try parseProxyMapping(gpa, &parser, group);
            try nodes.append(gpa, node);
        } else {
            ev.deinit();
        }
    }

    return nodes.toOwnedSlice(gpa);
}

fn parseProxyMapping(gpa: std.mem.Allocator, parser: *libyaml.Parser, group: []const u8) !model.ProxyNode {
    var name: ?[]const u8 = null;
    var node_type: model.NodeType = .unknown;
    var server: ?[]const u8 = null;
    var port: u16 = 0;
    var params = std.StringHashMap(std.json.Value).init(gpa);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            model.deinitJsonValue(gpa, entry.value_ptr.*);
        }
        params.deinit();
        if (name) |n| gpa.free(n);
        if (server) |s| gpa.free(s);
    }

    while (true) {
        var key_ev = try parser.nextEvent();
        if (key_ev.eventType() == .mapping_end) {
            key_ev.deinit();
            break;
        }
        const key = try gpa.dupe(u8, key_ev.scalarValue());
        key_ev.deinit();

        var val_ev = try parser.nextEvent();
        const val_et = val_ev.eventType();

        if (std.mem.eql(u8, key, "name")) {
            if (val_et == .scalar) name = try gpa.dupe(u8, val_ev.scalarValue());
            gpa.free(key);
        } else if (std.mem.eql(u8, key, "type")) {
            if (val_et == .scalar) node_type = model.NodeType.fromString(val_ev.scalarValue());
            gpa.free(key);
        } else if (std.mem.eql(u8, key, "server")) {
            if (val_et == .scalar) server = try gpa.dupe(u8, val_ev.scalarValue());
            gpa.free(key);
        } else if (std.mem.eql(u8, key, "port")) {
            if (val_et == .scalar) {
                port = std.fmt.parseInt(u16, val_ev.scalarValue(), 10) catch 0;
            }
            gpa.free(key);
        } else {
            // Store as params - handle scalars, sequences, and mappings
            const val = try yamlValueToJson(gpa, parser, &val_ev);
            try params.put(key, val);
        }
        val_ev.deinit();
    }

    return .{
        .name = name orelse try gpa.dupe(u8, "unnamed"),
        .group = try gpa.dupe(u8, group),
        .node_type = node_type,
        .server = server orelse try gpa.dupe(u8, ""),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

fn yamlScalarToJson(gpa: std.mem.Allocator, ev: *const libyaml.Event) !std.json.Value {
    const s = ev.scalarValue();
    // Try parse as number
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return .{ .integer = n };
    } else |_| {}
    if (std.fmt.parseFloat(f64, s)) |f| {
        return .{ .float = f };
    } else |_| {}
    // Try parse as bool
    if (std.mem.eql(u8, s, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, s, "false")) return .{ .bool = false };
    // String
    return .{ .string = try gpa.dupe(u8, s) };
}

fn yamlValueToJson(gpa: std.mem.Allocator, parser: *libyaml.Parser, ev: *const libyaml.Event) !std.json.Value {
    const et = ev.eventType();
    if (et == .scalar) {
        return yamlScalarToJson(gpa, ev);
    } else if (et == .sequence_start) {
        var arr = std.json.Array.init(gpa);
        while (true) {
            var child_ev = try parser.nextEvent();
            if (child_ev.eventType() == .sequence_end) {
                child_ev.deinit();
                break;
            }
            const item = try yamlValueToJson(gpa, parser, &child_ev);
            child_ev.deinit();
            try arr.append(item);
        }
        return .{ .array = arr };
    } else if (et == .mapping_start) {
        var obj = try std.json.ObjectMap.init(gpa, &.{}, &.{});
        while (true) {
            var key_ev = try parser.nextEvent();
            if (key_ev.eventType() == .mapping_end) {
                key_ev.deinit();
                break;
            }
            const key = try gpa.dupe(u8, key_ev.scalarValue());
            key_ev.deinit();
            var val_ev = try parser.nextEvent();
            const val = try yamlValueToJson(gpa, parser, &val_ev);
            val_ev.deinit();
            try obj.put(gpa, key, val);
        }
        return .{ .object = obj };
    }
    return .null;
}
