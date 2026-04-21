const std = @import("std");
const httpz = @import("httpz");

const config = @import("config.zig");
const state = @import("state.zig");
const mihomo_manager = @import("mihomo_manager.zig");
const server_api = @import("server/api.zig");
const fetch_scheduler = @import("fetch/scheduler.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    defer args_iter.deinit();
    _ = args_iter.next();
    const config_path = args_iter.next() orelse "config.yaml";

    var cfg = try config.AppConfig.load(gpa, io, config_path);
    errdefer cfg.deinit(gpa);
    try cfg.validate();

    std.log.info("surge-enhancer starting with config: {s}", .{config_path});

    var app_state = state.AppState.init(gpa, io);
    app_state.config = cfg;
    app_state.config_path = try gpa.dupe(u8, config_path);
    defer app_state.deinit();

    const manager = try gpa.create(mihomo_manager.MihomoManager);
    manager.* = mihomo_manager.MihomoManager.init(io, gpa, cfg.mihomo);
    _ = io.async(mihomoManagerLoop, .{manager});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    fetch_scheduler.spawnRefreshTasks(&app_state, &client);

    const address = try std.Io.net.IpAddress.parseLiteral(cfg.server.listen);
    var srv = try httpz.Server(*state.AppState).init(io, gpa, .{
        .address = .{ .ip = address },
    }, &app_state);
    defer srv.deinit();
    defer srv.stop();

    var router = try srv.router(.{});
    router.get("/", server_api.dashboard, .{});
    router.get("/surge/proxies", server_api.surgeProxies, .{});
    router.get("/surge/group/:name", server_api.surgeGroup, .{});
    router.get("/surge/config", server_api.surgeConfig, .{});
    router.post("/refresh", server_api.refreshAll, .{});
    router.post("/refresh/:name", server_api.refreshGroup, .{});
    router.get("/status", server_api.status, .{});
    router.get("/api/delay/:name", server_api.testDelay, .{});
    router.post("/api/batch-delay/:name", server_api.batchDelay, .{});
    router.post("/api/tcp-ping/:name", server_api.tcpPingGroup, .{});
    router.post("/api/groups", server_api.addGroup, .{});
    router.put("/api/groups/:name", server_api.updateGroup, .{});
    router.delete("/api/groups/:name", server_api.deleteGroup, .{});

    std.log.info("HTTP server listening on http://{s}", .{cfg.server.listen});
    try srv.listen();
}

fn mihomoManagerLoop(manager: *mihomo_manager.MihomoManager) void {
    manager.run();
}
