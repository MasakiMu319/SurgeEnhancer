const std = @import("std");
const model = @import("../model.zig");

pub fn parseBase64Uris(gpa: std.mem.Allocator, body: []const u8, group: []const u8) ![]model.ProxyNode {
    const decoded = try b64Decode(gpa, std.mem.trim(u8, body, " \t\r\n"));
    defer gpa.free(decoded);
    return try parseUriLines(gpa, decoded, group);
}

pub fn parseUriLines(gpa: std.mem.Allocator, text: []const u8, group: []const u8) ![]model.ProxyNode {
    var nodes = std.ArrayList(model.ProxyNode).empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(gpa);
        nodes.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const node = parseSingleUri(gpa, trimmed, group) catch |err| {
            std.log.warn("skipping unparseable proxy URI: {s} error={s}", .{ trimmed, @errorName(err) });
            continue;
        };
        try nodes.append(gpa, node);
    }

    return nodes.toOwnedSlice(gpa);
}

fn parseSingleUri(gpa: std.mem.Allocator, uri: []const u8, group: []const u8) !model.ProxyNode {
    if (std.mem.startsWith(u8, uri, "ss://")) {
        return try parseSs(gpa, uri[5..], group);
    }
    if (std.mem.startsWith(u8, uri, "vmess://")) {
        return try parseVmess(gpa, uri[8..], group);
    }
    if (std.mem.startsWith(u8, uri, "trojan://")) {
        return try parseTrojan(gpa, uri[9..], group);
    }
    if (std.mem.startsWith(u8, uri, "vless://")) {
        return try parseVless(gpa, uri[8..], group);
    }
    if (std.mem.startsWith(u8, uri, "hysteria2://")) {
        return try parseHysteria2(gpa, uri[12..], group);
    }
    if (std.mem.startsWith(u8, uri, "hy2://")) {
        return try parseHysteria2(gpa, uri[6..], group);
    }
    if (std.mem.startsWith(u8, uri, "anytls://")) {
        return try parseAnytls(gpa, uri[9..], group);
    }
    return error.UnsupportedProxyScheme;
}

fn parseSs(gpa: std.mem.Allocator, rest: []const u8, group: []const u8) !model.ProxyNode {
    const main, const name = try splitFragment(gpa, rest);
    defer gpa.free(main);

    var params = std.StringHashMap(std.json.Value).init(gpa);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            model.deinitJsonValue(gpa, entry.value_ptr.*);
        }
        params.deinit();
    }

    // Try SIP002: base64(userinfo)@host:port
    if (std.mem.indexOf(u8, main, "@")) |at| {
        const userinfo_b64 = main[0..at];
        const host_port = main[at + 1 ..];
        const userinfo = try b64Decode(gpa, userinfo_b64);
        defer gpa.free(userinfo);
        const colon = std.mem.indexOf(u8, userinfo, ":") orelse return error.InvalidSsUri;
        const method = userinfo[0..colon];
        const password = userinfo[colon + 1 ..];
        const host, const port = try parseHostPort(host_port);
        try params.put(try gpa.dupe(u8, "cipher"), .{ .string = try gpa.dupe(u8, method) });
        try params.put(try gpa.dupe(u8, "password"), .{ .string = try gpa.dupe(u8, password) });
        return .{
            .name = name,
            .group = try gpa.dupe(u8, group),
            .node_type = .ss,
            .server = try gpa.dupe(u8, host),
            .port = port,
            .params = params,
            .assigned_port = 0,
        };
    }

    // Legacy: base64(method:password@host:port)
    const decoded = try b64Decode(gpa, main);
    defer gpa.free(decoded);
    const at = std.mem.lastIndexOf(u8, decoded, "@") orelse return error.InvalidSsUri;
    const userinfo = decoded[0..at];
    const host_port = decoded[at + 1 ..];
    const colon = std.mem.indexOf(u8, userinfo, ":") orelse return error.InvalidSsUri;
    const method = userinfo[0..colon];
    const password = userinfo[colon + 1 ..];
    const host, const port = try parseHostPort(host_port);
    try params.put(try gpa.dupe(u8, "cipher"), .{ .string = try gpa.dupe(u8, method) });
    try params.put(try gpa.dupe(u8, "password"), .{ .string = try gpa.dupe(u8, password) });
    return .{
        .name = name,
        .group = try gpa.dupe(u8, group),
        .node_type = .ss,
        .server = try gpa.dupe(u8, host),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

fn parseVmess(gpa: std.mem.Allocator, rest: []const u8, group: []const u8) !model.ProxyNode {
    const hash = std.mem.indexOf(u8, rest, "#");
    const b64_part = if (hash) |i| rest[0..i] else rest;
    const decoded = try b64Decode(gpa, b64_part);
    defer gpa.free(decoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, decoded, .{});
    defer parsed.deinit();
    const json = parsed.value;

    const raw_name = jsonStr(&json, "ps") orelse jsonStr(&json, "remarks") orelse "unnamed";
    const name = try gpa.dupe(u8, raw_name);
    const server = jsonStr(&json, "add") orelse "";
    const port: u16 = blk: {
        if (json.object.get("port")) |p| {
            if (p == .string) break :blk std.fmt.parseInt(u16, p.string, 10) catch 0;
            if (p == .integer) break :blk @intCast(p.integer);
        }
        break :blk 0;
    };

    var params = std.StringHashMap(std.json.Value).init(gpa);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            model.deinitJsonValue(gpa, entry.value_ptr.*);
        }
        params.deinit();
    }

    const keys = &[_][]const u8{ "id", "aid", "net", "type", "host", "path", "tls", "sni", "alpn" };
    for (keys) |key| {
        if (json.object.get(key)) |v| {
            if (v != .null) {
                try params.put(try gpa.dupe(u8, key), try cloneJsonValue(gpa, v));
            }
        }
    }

    return .{
        .name = name,
        .group = try gpa.dupe(u8, group),
        .node_type = .vmess,
        .server = try gpa.dupe(u8, server),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

fn parseTrojan(gpa: std.mem.Allocator, rest: []const u8, group: []const u8) !model.ProxyNode {
    const main, const name = try splitFragment(gpa, rest);
    defer gpa.free(main);
    const at = std.mem.indexOf(u8, main, "@") orelse return error.InvalidTrojanUri;
    const password = main[0..at];
    const after = main[at + 1 ..];
    const host_port, const query = splitQuery(after);
    const host, const port = try parseHostPort(host_port);
    var params = try parseQueryParams(gpa, query);
    try params.put(try gpa.dupe(u8, "password"), .{ .string = try percentDecode(gpa, password) });
    return .{
        .name = name,
        .group = try gpa.dupe(u8, group),
        .node_type = .trojan,
        .server = try gpa.dupe(u8, host),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

fn parseVless(gpa: std.mem.Allocator, rest: []const u8, group: []const u8) !model.ProxyNode {
    const main, const name = try splitFragment(gpa, rest);
    defer gpa.free(main);
    const at = std.mem.indexOf(u8, main, "@") orelse return error.InvalidVlessUri;
    const uuid = main[0..at];
    const after = main[at + 1 ..];
    const host_port, const query = splitQuery(after);
    const host, const port = try parseHostPort(host_port);
    var params = try parseQueryParams(gpa, query);
    try params.put(try gpa.dupe(u8, "uuid"), .{ .string = try gpa.dupe(u8, uuid) });
    return .{
        .name = name,
        .group = try gpa.dupe(u8, group),
        .node_type = .vless,
        .server = try gpa.dupe(u8, host),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

fn parseHysteria2(gpa: std.mem.Allocator, rest: []const u8, group: []const u8) !model.ProxyNode {
    const main, const name = try splitFragment(gpa, rest);
    defer gpa.free(main);
    const at = std.mem.indexOf(u8, main, "@") orelse return error.InvalidHysteria2Uri;
    const auth = main[0..at];
    const after = main[at + 1 ..];
    const host_port, const query = splitQuery(after);
    const host, const port = try parseHostPort(host_port);
    var params = try parseQueryParams(gpa, query);
    try params.put(try gpa.dupe(u8, "password"), .{ .string = try percentDecode(gpa, auth) });
    return .{
        .name = name,
        .group = try gpa.dupe(u8, group),
        .node_type = .hysteria2,
        .server = try gpa.dupe(u8, host),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

fn parseAnytls(gpa: std.mem.Allocator, rest: []const u8, group: []const u8) !model.ProxyNode {
    const main, const name = try splitFragment(gpa, rest);
    defer gpa.free(main);
    const at = std.mem.indexOf(u8, main, "@") orelse return error.InvalidAnytlsUri;
    const password = main[0..at];
    const after = main[at + 1 ..];
    const host_port, const query = splitQuery(after);
    const host, const port = try parseHostPort(host_port);
    var params = try parseQueryParams(gpa, query);
    try params.put(try gpa.dupe(u8, "password"), .{ .string = try percentDecode(gpa, password) });
    return .{
        .name = name,
        .group = try gpa.dupe(u8, group),
        .node_type = .anytls,
        .server = try gpa.dupe(u8, host),
        .port = port,
        .params = params,
        .assigned_port = 0,
    };
}

// --- Helpers ---

fn splitFragment(gpa: std.mem.Allocator, s: []const u8) !struct { []const u8, []const u8 } {
    if (std.mem.indexOf(u8, s, "#")) |i| {
        return .{
            try gpa.dupe(u8, s[0..i]),
            try percentDecode(gpa, s[i + 1 ..]),
        };
    }
    return .{ try gpa.dupe(u8, s), try gpa.dupe(u8, "unnamed") };
}

fn splitQuery(s: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOf(u8, s, "?")) |i| {
        return .{ s[0..i], s[i + 1 ..] };
    }
    return .{ s, "" };
}

fn parseHostPort(s: []const u8) !struct { []const u8, u16 } {
    if (std.mem.startsWith(u8, s, "[")) {
        const end = std.mem.indexOf(u8, s, "]") orelse return error.InvalidHostPort;
        const ipv6 = s[1..end];
        const port_str = s[end + 2 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);
        return .{ ipv6, port };
    }
    const i = std.mem.lastIndexOf(u8, s, ":") orelse return error.InvalidHostPort;
    const host = s[0..i];
    const port = try std.fmt.parseInt(u16, s[i + 1 ..], 10);
    return .{ host, port };
}

fn parseQueryParams(gpa: std.mem.Allocator, query: []const u8) !std.StringHashMap(std.json.Value) {
    var params = std.StringHashMap(std.json.Value).init(gpa);
    errdefer {
        var it = params.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            model.deinitJsonValue(gpa, entry.value_ptr.*);
        }
        params.deinit();
    }
    if (query.len == 0) return params;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq| {
            const k = try gpa.dupe(u8, pair[0..eq]);
            const v = try percentDecode(gpa, pair[eq + 1 ..]);
            try params.put(k, .{ .string = v });
        }
    }
    return params;
}

fn percentDecode(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Simple percent decode
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try result.append(gpa, s[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try result.append(gpa, s[i]);
                i += 1;
                continue;
            };
            try result.append(gpa, @intCast(hi * 16 + lo));
            i += 3;
        } else {
            try result.append(gpa, s[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(gpa);
}

fn b64Decode(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");

    // Try standard base64 (with padding)
    if (std.base64.standard.Decoder.calcSizeForSlice(trimmed)) |len| {
        const buf = try gpa.alloc(u8, len);
        if (std.base64.standard.Decoder.decode(buf, trimmed)) |_| {
            return buf;
        } else |_| {
            gpa.free(buf);
        }
    } else |_| {}

    // Try standard base64 (no padding)
    if (std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed)) |len| {
        const buf = try gpa.alloc(u8, len);
        if (std.base64.standard_no_pad.Decoder.decode(buf, trimmed)) |_| {
            return buf;
        } else |_| {
            gpa.free(buf);
        }
    } else |_| {}

    // Try URL-safe base64: replace - with + and _ with /
    const converted = try gpa.dupe(u8, trimmed);
    defer gpa.free(converted);
    for (converted) |*c| {
        if (c.* == '-') c.* = '+';
        if (c.* == '_') c.* = '/';
    }

    if (std.base64.standard.Decoder.calcSizeForSlice(converted)) |len| {
        const buf = try gpa.alloc(u8, len);
        if (std.base64.standard.Decoder.decode(buf, converted)) |_| {
            return buf;
        } else |_| {
            gpa.free(buf);
        }
    } else |_| {}

    if (std.base64.standard_no_pad.Decoder.calcSizeForSlice(converted)) |len| {
        const buf = try gpa.alloc(u8, len);
        if (std.base64.standard_no_pad.Decoder.decode(buf, converted)) |_| {
            return buf;
        } else |_| {
            gpa.free(buf);
        }
    } else |_| {}

    // Lenient fallback: strip internal '=' padding then retry
    // Some proxy subscriptions embed '=' inside base64 (e.g. SS SIP002 with
    // nested base64 passwords). Strip trailing '=', then try no_pad decoder.
    var stripped = std.ArrayList(u8).empty;
    defer stripped.deinit(gpa);
    for (trimmed) |c| {
        if (c != '=') {
            try stripped.append(gpa, c);
        }
    }
    // Also apply URL-safe conversion
    for (stripped.items) |*c| {
        if (c.* == '-') c.* = '+';
        if (c.* == '_') c.* = '/';
    }

    if (std.base64.standard_no_pad.Decoder.calcSizeForSlice(stripped.items)) |len| {
        const buf = try gpa.alloc(u8, len);
        if (std.base64.standard_no_pad.Decoder.decode(buf, stripped.items)) |_| {
            return buf;
        } else |_| {
            gpa.free(buf);
        }
    } else |_| {}

    return error.InvalidCharacter;
}

fn jsonStr(json: *const std.json.Value, key: []const u8) ?[]const u8 {
    if (json.object.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn cloneJsonValue(gpa: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try gpa.dupe(u8, s) },
        .string => |s| .{ .string = try gpa.dupe(u8, s) },
        .array => |arr| blk: {
            var new = std.json.Array.init(gpa);
            errdefer {
                for (new.items) |item| model.deinitJsonValue(gpa, item);
                new.deinit();
            }
            for (arr.items) |item| {
                try new.append(try cloneJsonValue(gpa, item));
            }
            break :blk .{ .array = new };
        },
        .object => |obj| blk: {
            var new = try std.json.ObjectMap.init(gpa, &.{}, &.{});
            errdefer {
                var it = new.iterator();
                while (it.next()) |entry| {
                    gpa.free(entry.key_ptr.*);
                    model.deinitJsonValue(gpa, entry.value_ptr.*);
                }
                new.deinit(gpa);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                try new.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), try cloneJsonValue(gpa, entry.value_ptr.*));
            }
            break :blk .{ .object = new };
        },
    };
}


