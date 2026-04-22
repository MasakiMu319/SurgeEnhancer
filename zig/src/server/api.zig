const std = @import("std");
const httpz = @import("httpz");
const state = @import("../state.zig");
const config = @import("../config.zig");
const model = @import("../model.zig");
const generate = @import("../generate/mihomo.zig");
const surge_gen = @import("../generate/surge.zig");
const mihomo_api = @import("../mihomo_api.zig");
const scheduler = @import("../fetch/scheduler.zig");

pub fn dashboard(_: *state.AppState, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = @embedFile("templates/dashboard.html");
}

pub fn surgeProxies(app: *state.AppState, _: *httpz.Request, res: *httpz.Response) !void {
    app.inner.lockShared();
    defer app.inner.unlockShared();

    var total: usize = 0;
    {
        var it = app.inner_data.groups.iterator();
        while (it.next()) |entry| total += entry.value_ptr.nodes.len;
    }
    if (total == 0) {
        res.content_type = .TEXT;
        res.body = "# No nodes available yet\n";
        return;
    }

    const listen_addr = app.config.port.listen_addr;
    var lines = std.ArrayList(u8).empty;
    try lines.ensureTotalCapacity(app.gpa, total * 64);
    var it = app.inner_data.groups.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.nodes) |node| {
            try lines.print(app.gpa, "{s} = socks5, {s}, {d}\n", .{ node.name, listen_addr, node.assigned_port });
        }
    }
    res.content_type = .TEXT;
    res.body = try lines.toOwnedSlice(app.gpa);
}

pub fn surgeGroup(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;
    app.inner.lockShared();
    defer app.inner.unlockShared();

    const entry = app.inner_data.groups.getEntry(name) orelse {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "# Group '{s}' not found\n", .{name});
        return;
    };

    const listen_addr = app.config.port.listen_addr;
    res.content_type = .TEXT;
    res.body = try surge_gen.generateSurgeProxyList(res.arena, entry.value_ptr.nodes, listen_addr);
}

pub fn surgeConfig(app: *state.AppState, _: *httpz.Request, res: *httpz.Response) !void {
    app.inner.lockShared();
    defer app.inner.unlockShared();

    var groups = try std.array_hash_map.String([]model.ProxyNode).init(app.gpa, &.{}, &.{});
    defer groups.deinit(app.gpa);
    var it = app.inner_data.groups.iterator();
    while (it.next()) |entry| {
        try groups.put(app.gpa, try app.gpa.dupe(u8, entry.key_ptr.*), entry.value_ptr.nodes);
    }

    res.content_type = .TEXT;
    res.body = try surge_gen.generateSurgeConfig(res.arena, app.config, &groups);
}

pub fn refreshAll(app: *state.AppState, _: *httpz.Request, res: *httpz.Response) !void {
    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    for (app.config.groups) |group| {
        try scheduler.doRefresh(app, &client, &group);
    }
    res.status = 202;
    res.content_type = .TEXT;
    res.body = "refresh triggered\n";
}

pub fn refreshGroup(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;
    const group = findGroupConfig(app, name) orelse {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "group '{s}' not found\n", .{name});
        return;
    };

    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    try scheduler.doRefresh(app, &client, &group);

    res.status = 202;
    res.content_type = .TEXT;
    res.body = try std.fmt.allocPrint(res.arena, "refresh triggered for '{s}'\n", .{name});
}

pub fn status(app: *state.AppState, _: *httpz.Request, res: *httpz.Response) !void {
    const server_listen = app.config.server.listen;
    const gpa = app.gpa;

    app.inner.lockShared();
    defer app.inner.unlockShared();

    var out = std.ArrayList(u8).empty;
    try out.ensureTotalCapacity(gpa, 32 * 1024);

    try out.appendSlice(gpa, "{\"total_nodes\":");
    var total_nodes: usize = 0;
    {
        var it = app.inner_data.groups.iterator();
        while (it.next()) |entry| {
            total_nodes += entry.value_ptr.nodes.len;
        }
    }
    try out.print(gpa, "{d}", .{total_nodes});

    try out.appendSlice(gpa, ",\"mihomo\":{\"status\":\"");
    try out.appendSlice(gpa, @tagName(app.inner_data.mihomo.status));
    try out.appendSlice(gpa, "\",\"pid\":");
    if (app.inner_data.mihomo.pid) |pid| {
        try out.print(gpa, "{d}", .{pid});
    } else {
        try out.appendSlice(gpa, "null");
    }
    try out.print(gpa, ",\"restarts\":{d},\"last_error\":", .{app.inner_data.mihomo.restarts});
    if (app.inner_data.mihomo.last_error) |e| {
        try writeJsonString(&out, gpa, e);
    } else {
        try out.appendSlice(gpa, "null");
    }
    try out.appendSlice(gpa, "},\"groups\":[");

    var first_group = true;
    var it = app.inner_data.groups.iterator();
    while (it.next()) |entry| {
        if (!first_group) try out.appendSlice(gpa, ",");
        first_group = false;

        try out.appendSlice(gpa, "{\"name\":");
        try writeJsonString(&out, gpa, entry.value_ptr.name);

        try out.appendSlice(gpa, ",\"status\":\"");
        try out.appendSlice(gpa, entry.value_ptr.status.toString());

        try out.print(gpa, "\",\"node_count\":{d},\"last_updated\":", .{entry.value_ptr.nodes.len});
        if (entry.value_ptr.last_updated) |t| {
            try out.print(gpa, "{d}", .{t});
        } else {
            try out.appendSlice(gpa, "null");
        }

        try out.appendSlice(gpa, ",\"last_error\":");
        if (entry.value_ptr.last_error) |e| {
            try writeJsonString(&out, gpa, e);
        } else {
            try out.appendSlice(gpa, "null");
        }

        try out.appendSlice(gpa, ",\"subscription\":");
        const group_cfg = findGroupConfigPtr(app, entry.key_ptr.*);
        const subscription: ?[]const u8 = if (group_cfg) |gc| blk: {
            if (gc.subscription) |s| break :blk s;
            if (gc.file) |f| break :blk f;
            break :blk null;
        } else null;
        if (subscription) |s| {
            try writeJsonString(&out, gpa, s);
        } else {
            try out.appendSlice(gpa, "null");
        }

        try out.appendSlice(gpa, ",\"surge_policy_path\":\"http://");
        try out.appendSlice(gpa, server_listen);
        try out.appendSlice(gpa, "/surge/group/");
        try out.appendSlice(gpa, entry.value_ptr.name);

        try out.appendSlice(gpa, "\",\"nodes\":[");
        for (entry.value_ptr.nodes, 0..) |node, i| {
            if (i > 0) try out.appendSlice(gpa, ",");
            try out.appendSlice(gpa, "{\"name\":");
            try writeJsonString(&out, gpa, node.name);
            try out.appendSlice(gpa, ",\"type\":\"");
            try out.appendSlice(gpa, node.node_type.toString());
            try out.appendSlice(gpa, "\",\"server\":");
            try writeJsonString(&out, gpa, node.server);
            try out.print(gpa, ",\"port\":{d},\"assigned_port\":{d}}}", .{ node.port, node.assigned_port });
        }
        try out.appendSlice(gpa, "]}");
    }

    try out.appendSlice(gpa, "]}");

    res.content_type = .JSON;
    res.body = try out.toOwnedSlice(gpa);
}

fn writeJsonString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) blk: {
                if (start < i) try out.appendSlice(gpa, s[start..i]);
                try out.print(gpa, "\\u{x:0>4}", .{c});
                start = i + 1;
                break :blk null;
            } else null,
        };
        if (esc) |e| {
            if (start < i) try out.appendSlice(gpa, s[start..i]);
            try out.appendSlice(gpa, e);
            start = i + 1;
        }
    }
    if (start < s.len) try out.appendSlice(gpa, s[start..]);
    try out.append(gpa, '"');
}


pub fn testDelay(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const node_name = req.param("name").?;
    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    const result = mihomo_api.testDelay(app.gpa, app.io, &client, app.config.mihomo, node_name) catch |err| {
        res.status = 502;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "mihomo delay test failed: {s}", .{@errorName(err)});
        return;
    };
    try res.json(result, .{});
}

pub fn batchDelay(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const group_name = req.param("name").?;
    app.inner.lockShared();
    defer app.inner.unlockShared();

    const entry = app.inner_data.groups.getEntry(group_name) orelse {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "group '{s}' not found\n", .{group_name});
        return;
    };

    var results = try std.json.ObjectMap.init(app.gpa, &.{}, &.{});
    defer {
        var it = results.iterator();
        while (it.next()) |e| {
            app.gpa.free(e.key_ptr.*);
            model.deinitJsonValue(app.gpa, e.value_ptr.*);
        }
        results.deinit(app.gpa);
    }

    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();

    for (entry.value_ptr.nodes) |node| {
        const val = mihomo_api.testDelay(app.gpa, app.io, &client, app.config.mihomo, node.name) catch |err| std.json.Value{
            .object = buildErrorObject(app.gpa, err) catch continue,
        };
        try results.put(app.gpa, try app.gpa.dupe(u8, node.name), val);
    }

    try res.json(.{ .results = std.json.Value{ .object = results } }, .{});
}

fn buildErrorObject(gpa: std.mem.Allocator, err: anyerror) !std.json.ObjectMap {
    var obj = try std.json.ObjectMap.init(gpa, &.{}, &.{});
    try obj.put(gpa, try gpa.dupe(u8, "message"), .{ .string = try std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) });
    return obj;
}

pub fn tcpPingGroup(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const group_name = req.param("name").?;
    app.inner.lockShared();
    defer app.inner.unlockShared();

    const entry = app.inner_data.groups.getEntry(group_name) orelse {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "group '{s}' not found\n", .{group_name});
        return;
    };

    const listen_addr = app.config.port.listen_addr;
    const timeout_ms: i32 = 5000;

    var results = std.ArrayList(std.json.Value).empty;
    defer {
        for (results.items) |v| model.deinitJsonValue(app.gpa, v);
        results.deinit(app.gpa);
    }

    for (entry.value_ptr.nodes) |node| {
        const addr = try std.fmt.allocPrint(app.gpa, "{s}:{d}", .{ node.server, node.port });
        defer app.gpa.free(addr);
        const direct_ms = tcpConnectMs(app.io, app.gpa, addr, timeout_ms) catch |err| std.json.Value{ .string = try std.fmt.allocPrint(app.gpa, "{s}", .{@errorName(err)}) };

        const proxy_addr = try std.fmt.allocPrint(app.gpa, "{s}:{d}", .{ listen_addr, node.assigned_port });
        defer app.gpa.free(proxy_addr);
        const proxy_ms = socks5ConnectMs(app.io, app.gpa, proxy_addr, "www.gstatic.com", 80, timeout_ms) catch |err| std.json.Value{ .string = try std.fmt.allocPrint(app.gpa, "{s}", .{@errorName(err)}) };

        const overhead = if (direct_ms == .integer and proxy_ms == .integer)
            std.json.Value{ .integer = proxy_ms.integer - direct_ms.integer }
        else
            std.json.Value.null;

        try results.append(app.gpa, .{ .object = buildPingResult(app.gpa, node.name, direct_ms, proxy_ms, overhead) catch continue });
    }

    try res.json(.{
        .group = group_name,
        .total = results.items.len,
        .results = results.items,
    }, .{});
}

fn buildPingResult(gpa: std.mem.Allocator, name: []const u8, direct: std.json.Value, proxy: std.json.Value, overhead: std.json.Value) !std.json.ObjectMap {
    var obj = try std.json.ObjectMap.init(gpa, &.{}, &.{});
    try obj.put(gpa, try gpa.dupe(u8, "name"), .{ .string = try gpa.dupe(u8, name) });
    try obj.put(gpa, try gpa.dupe(u8, "direct_tcp_ms"), if (direct == .integer) direct else .null);
    try obj.put(gpa, try gpa.dupe(u8, "direct_error"), if (direct == .string) direct else .null);
    try obj.put(gpa, try gpa.dupe(u8, "proxy_socks5_ms"), if (proxy == .integer) proxy else .null);
    try obj.put(gpa, try gpa.dupe(u8, "proxy_error"), if (proxy == .string) proxy else .null);
    try obj.put(gpa, try gpa.dupe(u8, "overhead_ms"), overhead);
    return obj;
}

fn tcpConnectMs(io: std.Io, gpa: std.mem.Allocator, addr: []const u8, timeout_ms: i32) !std.json.Value {
    _ = gpa;
    const start = std.Io.Clock.awake.now(io);
    const fd = try posixConnectWithTimeout(addr, timeout_ms);
    _ = std.c.close(fd);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    return .{ .integer = elapsed.toMilliseconds() };
}

fn socks5ConnectMs(io: std.Io, gpa: std.mem.Allocator, proxy: []const u8, target: []const u8, target_port: u16, timeout_ms: i32) !std.json.Value {
    const start = std.Io.Clock.awake.now(io);
    const fd = try posixConnectWithTimeout(proxy, timeout_ms);
    defer _ = std.c.close(fd);

    // Set recv/send timeout for SOCKS5 exchange
    const tv: std.c.timeval = .{
        .sec = @intCast(@divFloor(timeout_ms, 1000)),
        .usec = @intCast(@mod(timeout_ms, 1000) * 1000),
    };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.c.timeval));
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.c.timeval));

    // SOCKS5 greeting
    _ = try posixWrite(fd, &[_]u8{ 0x05, 0x01, 0x00 });
    var method_resp: [2]u8 = undefined;
    try posixReadExact(fd, &method_resp);
    if (method_resp[0] != 0x05) return error.NotSocks5;
    if (method_resp[1] == 0xFF) return error.NoAcceptableAuth;

    // CONNECT request
    var req_buf = std.ArrayList(u8).empty;
    defer req_buf.deinit(gpa);
    try req_buf.appendSlice(gpa, &[_]u8{ 0x05, 0x01, 0x00, 0x03, @intCast(target.len) });
    try req_buf.appendSlice(gpa, target);
    try req_buf.append(gpa, @intCast((target_port >> 8) & 0xFF));
    try req_buf.append(gpa, @intCast(target_port & 0xFF));
    _ = try posixWrite(fd, req_buf.items);

    // Read reply header
    var reply: [4]u8 = undefined;
    try posixReadExact(fd, &reply);

    // Drain bound address
    switch (reply[3]) {
        0x01 => { var skip: [6]u8 = undefined; try posixReadExact(fd, &skip); },
        0x03 => {
            var len_buf: [1]u8 = undefined;
            try posixReadExact(fd, &len_buf);
            const skip_len = @as(usize, len_buf[0]) + 2;
            var skip_buf: [258]u8 = undefined;
            try posixReadExact(fd, skip_buf[0..skip_len]);
        },
        0x04 => { var skip: [18]u8 = undefined; try posixReadExact(fd, &skip); },
        else => {},
    }

    if (reply[1] != 0x00) return error.Socks5ConnectFailed;

    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    return .{ .integer = elapsed.toMilliseconds() };
}

fn posixConnectWithTimeout(addr: []const u8, timeout_ms: i32) !std.c.fd_t {
    // Parse host:port
    const colon = std.mem.lastIndexOf(u8, addr, ":") orelse return error.InvalidAddress;
    const host = addr[0..colon];
    const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch return error.InvalidAddress;

    // Null-terminate host for getaddrinfo
    var host_buf: [256]u8 = undefined;
    if (host.len >= host_buf.len) return error.InvalidAddress;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return error.InvalidAddress;
    port_buf[port_str.len] = 0;

    var hints: std.c.addrinfo = .{
        .flags = .{},
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };

    var result: ?*std.c.addrinfo = null;
    const gai_rc = std.c.getaddrinfo(@ptrCast(host_buf[0 .. host.len + 1]), @ptrCast(port_buf[0 .. port_str.len + 1]), &hints, &result);
    if (@intFromEnum(gai_rc) != 0 or result == null) return error.InvalidAddress;
    defer std.c.freeaddrinfo(result.?);

    const ai = result.?;
    const fd = std.c.socket(@intCast(ai.family), std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer _ = std.c.close(fd);

    // Set non-blocking via fcntl (macOS doesn't support SOCK_NONBLOCK)
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | 0x0004); // O_NONBLOCK

    const rc = std.c.connect(fd, ai.addr.?, ai.addrlen);
    if (rc < 0) {
        const err = std.posix.errno(rc);
        if (err != .INPROGRESS) return error.ConnectFailed;

        var pfds = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 }};
        const prc = std.c.poll(&pfds, 1, timeout_ms);
        if (prc <= 0) return error.ConnectionTimedOut;

        // Check connect result
        var so_err: c_int = 0;
        var so_len: std.c.socklen_t = @sizeOf(c_int);
        _ = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, @ptrCast(&so_err), &so_len);
        if (so_err != 0) return error.ConnectionRefused;
    }

    // Clear NONBLOCK
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags); // restore original flags

    return fd;
}

fn posixWrite(fd: std.c.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.c.write(fd, data[written..].ptr, data[written..].len);
        if (rc < 0) return error.WriteFailed;
        written += @intCast(rc);
    }
}

fn posixReadExact(fd: std.c.fd_t, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = std.c.read(fd, buf[total..].ptr, buf[total..].len);
        if (rc <= 0) return error.ReadFailed;
        total += @intCast(rc);
    }
}

pub fn addGroup(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const body_opt = try req.json(config.GroupConfig);
    const body = body_opt orelse {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "invalid JSON body\n";
        return;
    };
    if (body.name.len == 0) {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "name is required\n";
        return;
    }
    if (body.subscription == null and body.file == null) {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "subscription or file is required\n";
        return;
    }

    app.inner.lock();
    defer app.inner.unlock();

    if (app.inner_data.groups.contains(body.name)) {
        res.status = 409;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "group '{s}' already exists\n", .{body.name});
        return;
    }

    // Update config — deep-copy body fields into gpa since body uses request arena
    var new_groups = try app.gpa.alloc(config.GroupConfig, app.config.groups.len + 1);
    @memcpy(new_groups[0..app.config.groups.len], app.config.groups);
    const idx = app.config.groups.len;
    new_groups[idx] = .{
        .name = try app.gpa.dupe(u8, body.name),
        .subscription = if (body.subscription) |s| try app.gpa.dupe(u8, s) else null,
        .file = if (body.file) |f| try app.gpa.dupe(u8, f) else null,
        .update_interval = body.update_interval,
        .filter = if (body.filter) |f| try app.gpa.dupe(u8, f) else null,
        .exclude_filter = if (body.exclude_filter) |f| try app.gpa.dupe(u8, f) else null,
    };
    app.gpa.free(app.config.groups);
    app.config.groups = new_groups;

    try app.config.save(app.gpa, app.io, app.config_path);

    // Add to runtime state
    const copied = new_groups[idx];
    const gs = try model.GroupState.init(app.gpa, copied.name);
    try app.inner_data.groups.put(app.gpa, try app.gpa.dupe(u8, copied.name), gs);

    // Trigger refresh
    scheduler.spawnSingleRefreshTask(app, copied);

    res.status = 201;
    res.content_type = .TEXT;
    res.body = try std.fmt.allocPrint(res.arena, "group '{s}' added\n", .{body.name});
}

pub fn updateGroup(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;
    const body_opt = try req.json(config.GroupConfig);
    const body = body_opt orelse {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "invalid JSON body\n";
        return;
    };

    app.inner.lock();
    var locked = true;
    defer if (locked) app.inner.unlock();

    var found = false;
    for (app.config.groups) |*g| {
        if (std.mem.eql(u8, g.name, name)) {
            if (body.subscription) |s| g.subscription = if (s.len == 0) null else try app.gpa.dupe(u8, s);
            if (body.file) |f| g.file = if (f.len == 0) null else try app.gpa.dupe(u8, f);
            if (body.update_interval > 0) g.update_interval = body.update_interval;
            if (body.filter) |f| g.filter = if (f.len == 0) null else try app.gpa.dupe(u8, f);
            if (body.exclude_filter) |f| g.exclude_filter = if (f.len == 0) null else try app.gpa.dupe(u8, f);
            found = true;
            break;
        }
    }

    if (!found) {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "group '{s}' not found\n", .{name});
        return;
    }

    try app.config.save(app.gpa, app.io, app.config_path);

    locked = false;
    app.inner.unlock();

    // doRefresh acquires its own lock
    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    const group = findGroupConfig(app, name) orelse return;
    try scheduler.doRefresh(app, &client, &group);

    res.content_type = .TEXT;
    res.body = try std.fmt.allocPrint(res.arena, "group '{s}' updated\n", .{name});
}

pub fn deleteGroup(app: *state.AppState, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;

    app.inner.lock();
    var locked = true;
    defer if (locked) app.inner.unlock();

    var found_idx: ?usize = null;
    for (app.config.groups, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, name)) {
            found_idx = i;
            break;
        }
    }

    if (found_idx == null) {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "group '{s}' not found\n", .{name});
        return;
    }

    // Remove from config
    const idx = found_idx.?;
    var new_groups = try app.gpa.alloc(config.GroupConfig, app.config.groups.len - 1);
    @memcpy(new_groups[0..idx], app.config.groups[0..idx]);
    @memcpy(new_groups[idx..], app.config.groups[idx + 1 ..]);
    app.gpa.free(app.config.groups);
    app.config.groups = new_groups;
    try app.config.save(app.gpa, app.io, app.config_path);

    // Remove from runtime state
    if (app.inner_data.groups.getEntry(name)) |entry| {
        for (entry.value_ptr.nodes) |*node| {
            _ = app.inner_data.port_map.remove(node.name);
        }
        entry.value_ptr.deinit(app.gpa);
        _ = app.inner_data.groups.swapRemove(name);
    }

    // Regenerate configs
    var all_nodes = std.ArrayList(model.ProxyNode).empty;
    defer all_nodes.deinit(app.gpa);
    var it = app.inner_data.groups.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.nodes) |node| {
            try all_nodes.append(app.gpa, node);
        }
    }

    locked = false;
    app.inner.unlock();

    generate.generateMihomoConfig(app.gpa, app.io, app.config, all_nodes.items) catch |err| {
        std.log.err("failed to regenerate configs: {s}", .{@errorName(err)});
    };

    var client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer client.deinit();
    mihomo_api.reloadConfig(app.gpa, app.io, &client, app.config.mihomo) catch |err| {
        std.log.warn("failed to reload mihomo: {s}", .{@errorName(err)});
    };

    res.content_type = .TEXT;
    res.body = try std.fmt.allocPrint(res.arena, "group '{s}' deleted\n", .{name});
}

fn findGroupConfig(app: *state.AppState, name: []const u8) ?config.GroupConfig {
    for (app.config.groups) |g| {
        if (std.mem.eql(u8, g.name, name)) return g;
    }
    return null;
}

fn findGroupConfigPtr(app: *state.AppState, name: []const u8) ?*config.GroupConfig {
    for (app.config.groups) |*g| {
        if (std.mem.eql(u8, g.name, name)) return g;
    }
    return null;
}
