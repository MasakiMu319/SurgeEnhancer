const std = @import("std");
const state = @import("../state.zig");
const config = @import("../config.zig");
const model = @import("../model.zig");
const fetcher = @import("fetcher.zig");
const generate = @import("../generate/mihomo.zig");
const port = @import("../port.zig");
const mihomo_api = @import("../mihomo_api.zig");

pub fn spawnRefreshTasks(app: *state.AppState, client: *std.http.Client) void {
    const gpa = app.gpa;
    const io = app.io;
    for (app.config.groups) |group| {
        const group_copy = tryCopyGroupConfig(gpa, group) catch continue;
        _ = io.async(refreshLoop, .{ app, client, group_copy });
    }
}

pub fn spawnSingleRefreshTask(app: *state.AppState, client: *std.http.Client, group: config.GroupConfig) void {
    const group_copy = tryCopyGroupConfig(app.gpa, group) catch return;
    _ = app.io.async(refreshLoop, .{ app, client, group_copy });
}

fn refreshLoop(app: *state.AppState, client: *std.http.Client, group: config.GroupConfig) void {
    const gpa = app.gpa;
    const io = app.io;

    // Initial refresh using the provided client
    doRefresh(app, client, &group) catch |err| { std.log.err("refresh failed for  ++ group.name ++ : {s}", .{@errorName(err)}); };

    while (true) {
        io.sleep(std.Io.Duration.fromSeconds(@intCast(group.update_interval)), .real) catch break;
        std.log.info("scheduled refresh: {s}", .{group.name});
        var fresh_client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer fresh_client.deinit();
        doRefresh(app, &fresh_client, &group) catch |err| { std.log.err("refresh failed for  ++ group.name ++ : {s}", .{@errorName(err)}); };
    }

    // Cleanup copied config
    gpa.free(group.name);
    if (group.subscription) |s| gpa.free(s);
    if (group.file) |s| gpa.free(s);
    if (group.filter) |s| gpa.free(s);
    if (group.exclude_filter) |s| gpa.free(s);
}

pub fn doRefresh(app: *state.AppState, client: *std.http.Client, group: *const config.GroupConfig) !void {
    const gpa = app.gpa;
    const io = app.io;

    const nodes = fetcher.fetchGroup(gpa, io, client, group.*) catch |err| {
        std.log.warn("fetch failed for '{s}': {s}", .{ group.name, @errorName(err) });
        app.inner.lock();
        defer app.inner.unlock();
        if (app.inner_data.groups.getEntry(group.name)) |entry| {
            entry.value_ptr.last_error = std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) catch null;
            entry.value_ptr.status = .error_status;
        }
        return;
    };

    app.inner.lock();

    // Remove old ports
    if (app.inner_data.groups.getEntry(group.name)) |entry| {
        for (entry.value_ptr.nodes) |*node| {
            _ = app.inner_data.port_map.remove(node.name);
        }
        entry.value_ptr.deinit(gpa);
    }

    // Assign ports
    const new_ports = port.assignPorts(gpa, nodes, app.config.port.range_start, &app.inner_data.port_map) catch |err| {
        std.log.err("port assignment failed: {s}", .{@errorName(err)});
        for (nodes) |*node| node.deinit(gpa);
        gpa.free(nodes);
        app.inner.unlock();
        return;
    };
    var pit = new_ports.iterator();
    while (pit.next()) |entry| {
        app.inner_data.port_map.put(gpa.dupe(u8, entry.key_ptr.*) catch {
            app.inner.unlock();
            return;
        }, entry.value_ptr.*) catch {
            app.inner.unlock();
            return;
        };
    }

    // Update group state
    const gs = model.GroupState{
        .name = gpa.dupe(u8, group.name) catch {
            app.inner.unlock();
            return;
        },
        .nodes = nodes,
        .last_updated = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)),
        .last_error = null,
        .status = .ok,
    };
    app.inner_data.groups.put(gpa, gpa.dupe(u8, group.name) catch {
        app.inner.unlock();
        return;
    }, gs) catch {
        app.inner.unlock();
        return;
    };

    // Regenerate configs
    const all_nodes = collectAllNodes(gpa, &app.inner_data) catch {
        app.inner.unlock();
        return;
    };
    defer gpa.free(all_nodes);

    app.inner.unlock();

    generate.generateMihomoConfig(gpa, io, app.config, all_nodes) catch |err| {
        std.log.err("failed to regenerate mihomo config: {s}", .{@errorName(err)});
    };
    mihomo_api.reloadConfig(gpa, io, client, app.config.mihomo) catch |err| {
        std.log.warn("failed to reload mihomo: {s}", .{@errorName(err)});
    };
}

fn collectAllNodes(gpa: std.mem.Allocator, inner: *state.AppStateInner) ![]model.ProxyNode {
    var total: usize = 0;
    var it = inner.groups.iterator();
    while (it.next()) |entry| {
        total += entry.value_ptr.nodes.len;
    }
    var all = try gpa.alloc(model.ProxyNode, total);
    var idx: usize = 0;
    it = inner.groups.iterator();
    while (it.next()) |entry| {
        @memcpy(all[idx..][0..entry.value_ptr.nodes.len], entry.value_ptr.nodes);
        idx += entry.value_ptr.nodes.len;
    }
    return all;
}

fn tryCopyGroupConfig(gpa: std.mem.Allocator, group: config.GroupConfig) !config.GroupConfig {
    return .{
        .name = try gpa.dupe(u8, group.name),
        .subscription = if (group.subscription) |s| try gpa.dupe(u8, s) else null,
        .file = if (group.file) |s| try gpa.dupe(u8, s) else null,
        .update_interval = group.update_interval,
        .filter = if (group.filter) |s| try gpa.dupe(u8, s) else null,
        .exclude_filter = if (group.exclude_filter) |s| try gpa.dupe(u8, s) else null,
    };
}

