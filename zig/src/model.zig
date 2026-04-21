const std = @import("std");

pub const NodeType = enum {
    ss,
    ssr,
    vmess,
    vless,
    trojan,
    hysteria2,
    tuic,
    anytls,
    unknown,

    pub fn fromString(s: []const u8) NodeType {
        if (std.mem.eql(u8, s, "ss")) return .ss;
        if (std.mem.eql(u8, s, "ssr")) return .ssr;
        if (std.mem.eql(u8, s, "vmess")) return .vmess;
        if (std.mem.eql(u8, s, "vless")) return .vless;
        if (std.mem.eql(u8, s, "trojan")) return .trojan;
        if (std.mem.eql(u8, s, "hysteria2")) return .hysteria2;
        if (std.mem.eql(u8, s, "tuic")) return .tuic;
        if (std.mem.eql(u8, s, "anytls")) return .anytls;
        return .unknown;
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .ss => "ss",
            .ssr => "ssr",
            .vmess => "vmess",
            .vless => "vless",
            .trojan => "trojan",
            .hysteria2 => "hysteria2",
            .tuic => "tuic",
            .anytls => "anytls",
            .unknown => "unknown",
        };
    }
};

pub const ProxyNode = struct {
    name: []const u8,
    group: []const u8,
    node_type: NodeType,
    server: []const u8,
    port: u16,
    params: std.StringHashMap(std.json.Value),
    assigned_port: u16,

    pub fn deinit(self: *ProxyNode, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.group);
        gpa.free(self.server);
        var it = self.params.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            deinitJsonValue(gpa, entry.value_ptr.*);
        }
        self.params.deinit();
    }
};

pub fn deinitJsonValue(gpa: std.mem.Allocator, v: std.json.Value) void {
    var v_mut = v;
    switch (v_mut) {
        .string => |s| gpa.free(s),
        .array => |*arr| {
            for (arr.items) |item| {
                deinitJsonValue(gpa, item);
            }
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                deinitJsonValue(gpa, entry.value_ptr.*);
            }
            obj.deinit(gpa);
        },
        else => {},
    }
}

pub const GroupStatus = enum {
    ok,
    error_status,
    pending,

    pub fn toString(self: GroupStatus) []const u8 {
        return switch (self) {
            .ok => "Ok",
            .error_status => "Error",
            .pending => "Pending",
        };
    }
};

pub const GroupState = struct {
    name: []const u8,
    nodes: []ProxyNode,
    last_updated: ?i64, // unix timestamp
    last_error: ?[]const u8,
    status: GroupStatus,

    pub fn init(gpa: std.mem.Allocator, name: []const u8) !GroupState {
        return .{
            .name = try gpa.dupe(u8, name),
            .nodes = &.{},
            .last_updated = null,
            .last_error = null,
            .status = .pending,
        };
    }

    pub fn deinit(self: *GroupState, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.last_error) |e| gpa.free(e);
        for (self.nodes) |*node| {
            node.deinit(gpa);
        }
        gpa.free(self.nodes);
    }
};

pub const NodeHealth = struct {
    alive: bool = false,
    delay: ?u64 = null,
};

pub const MihomoStatus = enum {
    running,
    stopped,
    starting,
    crashed,
};

pub const MihomoState = struct {
    status: MihomoStatus = .stopped,
    pid: ?u32 = null,
    restarts: u32 = 0,
    last_error: ?[]const u8 = null,

    pub fn deinit(self: *MihomoState, gpa: std.mem.Allocator) void {
        if (self.last_error) |e| gpa.free(e);
    }
};
