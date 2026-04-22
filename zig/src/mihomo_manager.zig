const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");
const state = @import("state.zig");
const mihomo_api = @import("mihomo_api.zig");

pub const MihomoManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    shared_state: *model.MihomoState,
    lock: *state.ThreadRwLock,
    mihomo_config: config.MihomoConfig,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, mcfg: config.MihomoConfig, shared_state: *model.MihomoState, lock: *state.ThreadRwLock) MihomoManager {
        return .{
            .gpa = gpa,
            .io = io,
            .shared_state = shared_state,
            .lock = lock,
            .mihomo_config = mcfg,
        };
    }

    fn updateState(self: *MihomoManager, s: model.MihomoStatus, pid: ?u32, last_error: ?[]const u8, inc_restarts: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.shared_state.last_error) |e| self.gpa.free(e);
        self.shared_state.status = s;
        if (pid) |p| self.shared_state.pid = p;
        self.shared_state.last_error = last_error;
        if (inc_restarts) self.shared_state.restarts += 1;
    }

    fn clearPid(self: *MihomoManager) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.shared_state.pid = null;
    }

    pub fn run(self: *MihomoManager) void {
        const io = self.io;
        const HEALTH_INTERVAL: u64 = 10 * std.time.ns_per_s;

        while (true) {
            if (self.isApiAlive()) {
                std.log.info("mihomo API already reachable", .{});
                self.updateState(.running, null, null, false);
                self.healthLoop(HEALTH_INTERVAL);
                std.log.warn("mihomo API lost, will attempt restart", .{});
            }

            self.updateState(.starting, null, null, false);
            var child = self.startProcess() catch |err| {
                std.log.err("failed to start mihomo: {s}", .{@errorName(err)});
                self.updateState(.crashed, null, std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch null, false);
                io.sleep(std.Io.Duration.fromSeconds(5), .real) catch break;
                continue;
            };

            const pid: u32 = @intCast(child.id orelse 0);
            std.log.info("mihomo process started pid={d}", .{pid});
            self.updateState(.starting, pid, null, false);

            // Wait for API to come up
            io.sleep(std.Io.Duration.fromSeconds(3), .real) catch break;
            var api_up = false;
            var retry: u32 = 0;
            while (retry < 5) : (retry += 1) {
                if (self.isApiAlive()) {
                    api_up = true;
                    break;
                }
                io.sleep(std.Io.Duration.fromSeconds(1), .real) catch break;
            }

            if (api_up) {
                std.log.info("mihomo API is up", .{});
                self.updateState(.running, null, null, false);
            } else {
                std.log.warn("mihomo started but API not responding", .{});
                self.updateState(.running, null, std.fmt.allocPrint(self.gpa, "API not responding after start", .{}) catch null, false);
            }

            // Monitor: block until child exits
            self.monitorLoop(&child, HEALTH_INTERVAL);

            self.updateState(.crashed, null, null, true);
            self.clearPid();
            std.log.warn("mihomo exited, restarts={d}", .{self.shared_state.restarts});
            io.sleep(std.Io.Duration.fromSeconds(5), .real) catch break;
        }
    }

    fn isApiAlive(self: *MihomoManager) bool {
        const url = std.mem.trimEnd(u8, self.mihomo_config.api, "/");
        const full = std.fmt.allocPrint(self.gpa, "{s}/version", .{url}) catch return false;
        defer self.gpa.free(full);

        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();

        var req = client.request(.GET, std.Uri.parse(full) catch return false, .{}) catch return false;
        var buf: [256]u8 = undefined;
        if (self.mihomo_config.api_secret) |secret| {
            const auth = std.fmt.bufPrint(&buf, "Bearer {s}", .{secret}) catch return false;
            req.headers.authorization = .{ .override = auth };
        }
        defer req.deinit();

        req.sendBodiless() catch return false;
        var response = req.receiveHead(&.{}) catch return false;
        return response.head.status.class() == .success;
    }

    fn startProcess(self: *MihomoManager) !std.process.Child {
        return std.process.spawn(self.io, .{
            .argv = &.{ "mihomo", "-f", self.mihomo_config.output },
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }

    fn monitorLoop(self: *MihomoManager, child: *std.process.Child, health_interval_ns: u64) void {
        const io = self.io;
        var failures: u32 = 0;
        _ = health_interval_ns;

        while (true) {
            {
                if (self.isApiAlive()) {
                    failures = 0;
                } else {
                    failures += 1;
                    std.log.warn("mihomo health check failed failures={d}", .{failures});
                    if (failures >= 3) {
                        std.log.err("mihomo unresponsive, killing process", .{});
                        child.kill(io);
                        self.updateState(.crashed, null, std.fmt.allocPrint(self.gpa, "killed: API unreachable", .{}) catch null, false);
                        return;
                    }
                }
            }

            // Check if child exited (non-blocking poll)
            const term = child.wait(io) catch {
                io.sleep(std.Io.Duration.fromSeconds(1), .real) catch return;
                continue;
            };
            self.updateState(.crashed, null, std.fmt.allocPrint(self.gpa, "process exited: {}", .{term}) catch null, false);
            return;
        }
    }

    fn healthLoop(self: *MihomoManager, interval_ns: u64) void {
        const io = self.io;
        var failures: u32 = 0;
        while (true) {
            io.sleep(std.Io.Duration.fromNanoseconds(@intCast(interval_ns)), .real) catch return;
            if (self.isApiAlive()) {
                failures = 0;
            } else {
                failures += 1;
                std.log.warn("mihomo health check failed failures={d}", .{failures});
                if (failures >= 3) {
                    self.updateState(.crashed, null, std.fmt.allocPrint(self.gpa, "API unreachable (3 failures)", .{}) catch null, false);
                    return;
                }
            }
        }
    }
};
