const std = @import("std");
const config = @import("config.zig");
const model = @import("model.zig");

pub const ThreadRwLock = struct {
    rwl: std.c.pthread_rwlock_t = .{},

    pub fn lockShared(self: *ThreadRwLock) void {
        _ = std.c.pthread_rwlock_rdlock(&self.rwl);
    }

    pub fn unlockShared(self: *ThreadRwLock) void {
        _ = std.c.pthread_rwlock_unlock(&self.rwl);
    }

    pub fn lock(self: *ThreadRwLock) void {
        _ = std.c.pthread_rwlock_wrlock(&self.rwl);
    }

    pub fn unlock(self: *ThreadRwLock) void {
        _ = std.c.pthread_rwlock_unlock(&self.rwl);
    }
};

pub const AppStateInner = struct {
    groups: std.array_hash_map.String(model.GroupState),
    port_map: std.StringHashMap(u16),
    mihomo_health: std.StringHashMap(model.NodeHealth),
    mihomo: model.MihomoState,

    pub fn init(gpa: std.mem.Allocator) AppStateInner {
        return .{
            .groups = .empty,
            .port_map = std.StringHashMap(u16).init(gpa),
            .mihomo_health = std.StringHashMap(model.NodeHealth).init(gpa),
            .mihomo = .{},
        };
    }

    pub fn deinit(self: *AppStateInner, gpa: std.mem.Allocator) void {
        var it = self.groups.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(gpa);
        }
        self.groups.deinit(gpa);
        self.port_map.deinit();
        self.mihomo_health.deinit();
        self.mihomo.deinit(gpa);
    }
};

pub const AppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    inner: ThreadRwLock,
    inner_data: AppStateInner,
    config: config.AppConfig,
    config_path: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) AppState {
        return .{
            .gpa = gpa,
            .io = io,
            .inner = .{},
            .inner_data = AppStateInner.init(gpa),
            .config = undefined,
            .config_path = "config.yaml",
        };
    }

    pub fn deinit(self: *AppState) void {
        self.config.deinit(self.gpa);
        self.inner_data.deinit(self.gpa);
    }
};
