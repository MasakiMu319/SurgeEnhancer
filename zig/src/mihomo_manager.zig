const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");
const mihomo_api = @import("mihomo_api.zig");

pub const MihomoManager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    state: model.MihomoState,
    mihomo_config: config.MihomoConfig,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, mcfg: config.MihomoConfig) MihomoManager {
        return .{
            .gpa = gpa,
            .io = io,
            .state = .{},
            .mihomo_config = mcfg,
        };
    }

    pub fn deinit(self: *MihomoManager) void {
        self.state.deinit(self.gpa);
    }

    pub fn findBinary(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "which", "mihomo" },
        }) catch return null;
        defer {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
        }
        if (result.term == .exited and result.term.exited == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        return null;
    }

    pub fn run(self: *MihomoManager) void {
        const io = self.io;
        const HEALTH_INTERVAL: u64 = 10 * std.time.ns_per_s;

        while (true) {
            if (self.isApiAlive()) {
                std.log.info("mihomo API already reachable", .{});
                self.state.status = .running;
                self.state.last_error = null;
                self.healthLoop(HEALTH_INTERVAL);
                std.log.warn("mihomo API lost, will attempt restart", .{});
            }

            self.state.status = .starting;
            var child = self.startProcess() catch |err| {
                std.log.err("failed to start mihomo: {s}", .{@errorName(err)});
                self.state.status = .crashed;
                self.state.last_error = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch null;
                io.sleep(std.Io.Duration.fromSeconds(5), .real) catch break;
                continue;
            };

            self.state.pid = @intCast(child.id orelse 0);
            std.log.info("mihomo process started pid={?}", .{child.id});

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
                self.state.status = .running;
                self.state.last_error = null;
            } else {
                std.log.warn("mihomo started but API not responding", .{});
                self.state.status = .running;
                self.state.last_error = std.fmt.allocPrint(self.gpa, "API not responding after start", .{}) catch null;
            }

            // Monitor: block until child exits
            self.monitorLoop(&child, HEALTH_INTERVAL);

            self.state.status = .crashed;
            self.state.pid = null;
            self.state.restarts += 1;
            std.log.warn("mihomo exited, restarts={d}", .{self.state.restarts});
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
        if (self.mihomo_config.api_secret) |secret| {
            var buf: [256]u8 = undefined;
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
            .stderr = .pipe,
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
                        self.state.last_error = std.fmt.allocPrint(self.gpa, "killed: API unreachable", .{}) catch null;
                        return;
                    }
                }
            }

            // Check if child exited (non-blocking poll)
            const term = child.wait(io) catch {
                io.sleep(std.Io.Duration.fromSeconds(1), .real) catch return;
                continue;
            };
            self.state.last_error = std.fmt.allocPrint(self.gpa, "process exited: {}", .{term}) catch null;
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
                    self.state.status = .crashed;
                    self.state.last_error = std.fmt.allocPrint(self.gpa, "API unreachable (3 failures)", .{}) catch null;
                    return;
                }
            }
        }
    }
};
