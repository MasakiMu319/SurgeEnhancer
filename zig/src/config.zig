const std = @import("std");
const libyaml = @import("libyaml.zig");

pub const AppConfig = struct {
    server: ServerConfig,
    mihomo: MihomoConfig,
    port: PortConfig,
    groups: []GroupConfig,

    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !AppConfig {
        if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) {
            return loadYaml(gpa, io, path);
        }
        return loadJson(gpa, io, path);
    }

    fn loadJson(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !AppConfig {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(content);

        const parsed = try std.json.parseFromSlice(AppConfig, gpa, content, .{});
        defer parsed.deinit();

        var cfg = parsed.value;
        cfg.server.listen = try gpa.dupe(u8, cfg.server.listen);
        cfg.server.log_level = try gpa.dupe(u8, cfg.server.log_level);
        cfg.mihomo.template = try gpa.dupe(u8, cfg.mihomo.template);
        cfg.mihomo.output = try gpa.dupe(u8, cfg.mihomo.output);
        cfg.mihomo.api = try gpa.dupe(u8, cfg.mihomo.api);
        if (cfg.mihomo.api_secret) |s| {
            cfg.mihomo.api_secret = try gpa.dupe(u8, s);
        }
        cfg.port.listen_addr = try gpa.dupe(u8, cfg.port.listen_addr);

        var groups = try gpa.alloc(GroupConfig, cfg.groups.len);
        for (cfg.groups, 0..) |g, i| {
            groups[i] = .{
                .name = try gpa.dupe(u8, g.name),
                .subscription = if (g.subscription) |s| try gpa.dupe(u8, s) else null,
                .file = if (g.file) |s| try gpa.dupe(u8, s) else null,
                .update_interval = g.update_interval,
                .filter = if (g.filter) |s| try gpa.dupe(u8, s) else null,
                .exclude_filter = if (g.exclude_filter) |s| try gpa.dupe(u8, s) else null,
            };
        }
        cfg.groups = groups;
        return cfg;
    }

    fn loadYaml(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !AppConfig {
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(content);

        var parser = try libyaml.Parser.init();
        defer parser.deinit();
        parser.setInputString(content);

        try expectEvent(&parser, .stream_start);
        try expectEvent(&parser, .document_start);
        try expectEvent(&parser, .mapping_start);

        var server: ?ServerConfig = null;
        var mihomo: ?MihomoConfig = null;
        var port: ?PortConfig = null;
        var groups: ?[]GroupConfig = null;

        while (true) {
            var key_ev = try parser.nextEvent();
            const ket = key_ev.eventType();
            if (ket == .mapping_end) {
                key_ev.deinit();
                break;
            }
            if (ket != .scalar) {
                key_ev.deinit();
                return error.ExpectedScalarKey;
            }
            const key = key_ev.scalarValue();
            if (std.mem.eql(u8, key, "server")) {
                key_ev.deinit();
                server = try parseServerMapping(&parser, gpa);
            } else if (std.mem.eql(u8, key, "mihomo")) {
                key_ev.deinit();
                mihomo = try parseMihomoMapping(&parser, gpa);
            } else if (std.mem.eql(u8, key, "port")) {
                key_ev.deinit();
                port = try parsePortMapping(&parser, gpa);
            } else if (std.mem.eql(u8, key, "groups")) {
                key_ev.deinit();
                groups = try parseGroupsSequence(&parser, gpa);
            } else {
                key_ev.deinit();
                try skipValue(&parser);
            }
        }

        try expectEvent(&parser, .document_end);
        try expectEvent(&parser, .stream_end);

        return AppConfig{
            .server = server orelse return error.MissingServerConfig,
            .mihomo = mihomo orelse return error.MissingMihomoConfig,
            .port = port orelse return error.MissingPortConfig,
            .groups = groups orelse try gpa.alloc(GroupConfig, 0),
        };
    }

    pub fn save(self: *const AppConfig, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(gpa);

        try out.print(gpa, "server:\n", .{});
        try out.print(gpa, "  listen: '{s}'\n", .{self.server.listen});
        try out.print(gpa, "  log_level: {s}\n", .{self.server.log_level});

        try out.print(gpa, "mihomo:\n", .{});
        try out.print(gpa, "  template: '{s}'\n", .{self.mihomo.template});
        try out.print(gpa, "  output: '{s}'\n", .{self.mihomo.output});
        try out.print(gpa, "  api: {s}\n", .{self.mihomo.api});
        if (self.mihomo.api_secret) |s| {
            try out.print(gpa, "  api_secret: '{s}'\n", .{s});
        } else {
            try out.print(gpa, "  api_secret: null\n", .{});
        }

        try out.print(gpa, "port:\n", .{});
        try out.print(gpa, "  range_start: {d}\n", .{self.port.range_start});
        try out.print(gpa, "  listen_addr: '{s}'\n", .{self.port.listen_addr});

        try out.print(gpa, "groups:\n", .{});
        for (self.groups) |g| {
            try out.print(gpa, "- name: {s}\n", .{g.name});
            try writeYamlNullable(gpa, &out, "  subscription", g.subscription);
            try writeYamlNullable(gpa, &out, "  file", g.file);
            try out.print(gpa, "  update_interval: {d}\n", .{g.update_interval});
            try writeYamlNullable(gpa, &out, "  filter", g.filter);
            try writeYamlNullable(gpa, &out, "  exclude_filter", g.exclude_filter);
        }

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    }

    pub fn validate(self: *const AppConfig) !void {
        if (self.groups.len == 0) {
            std.log.warn("no groups defined in config", .{});
        }
        for (self.groups) |g| {
            if (g.subscription == null and g.file == null) {
                return error.GroupMissingSource;
            }
        }
    }

    pub fn deinit(self: *AppConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.server.listen);
        gpa.free(self.server.log_level);
        gpa.free(self.mihomo.template);
        gpa.free(self.mihomo.output);
        gpa.free(self.mihomo.api);
        if (self.mihomo.api_secret) |s| gpa.free(s);
        gpa.free(self.port.listen_addr);
        for (self.groups) |g| {
            gpa.free(g.name);
            if (g.subscription) |s| gpa.free(s);
            if (g.file) |s| gpa.free(s);
            if (g.filter) |s| gpa.free(s);
            if (g.exclude_filter) |s| gpa.free(s);
        }
        gpa.free(self.groups);
    }
};

fn writeYamlNullable(gpa: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, val: ?[]const u8) !void {
    if (val) |s| {
        try out.print(gpa, "{s}: {s}\n", .{ key, s });
    } else {
        try out.print(gpa, "{s}: null\n", .{key});
    }
}

fn expectEvent(parser: *libyaml.Parser, expected: libyaml.EventType) !void {
    var ev = try parser.nextEvent();
    const et = ev.eventType();
    ev.deinit();
    if (et != expected) return error.UnexpectedYamlEvent;
}

fn skipValue(parser: *libyaml.Parser) !void {
    var ev = try parser.nextEvent();
    const et = ev.eventType();
    if (et == .mapping_start) {
        ev.deinit();
        try skipStructure(parser, .mapping_start);
    } else if (et == .sequence_start) {
        ev.deinit();
        try skipStructure(parser, .sequence_start);
    } else {
        ev.deinit();
    }
}

fn skipStructure(parser: *libyaml.Parser, start_type: libyaml.EventType) !void {
    var depth: usize = 1;
    while (depth > 0) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == start_type) depth += 1;
        if (et == .mapping_end and start_type == .mapping_start) depth -= 1;
        if (et == .sequence_end and start_type == .sequence_start) depth -= 1;
        ev.deinit();
    }
}

fn nextScalarOrNull(parser: *libyaml.Parser, gpa: std.mem.Allocator) !?[]const u8 {
    var ev = try parser.nextEvent();
    const et = ev.eventType();
    if (et == .scalar) {
        const val = ev.scalarValue();
        const is_null = std.mem.eql(u8, val, "null") or std.mem.eql(u8, val, "~") or val.len == 0;
        if (is_null) {
            ev.deinit();
            return null;
        }
        const duped = try gpa.dupe(u8, val);
        ev.deinit();
        return duped;
    }
    ev.deinit();
    if (et == .mapping_start) try skipStructure(parser, .mapping_start);
    if (et == .sequence_start) try skipStructure(parser, .sequence_start);
    return null;
}

fn parseServerMapping(parser: *libyaml.Parser, gpa: std.mem.Allocator) !ServerConfig {
    try expectEvent(parser, .mapping_start);
    var listen: ?[]const u8 = null;
    var log_level: ?[]const u8 = null;
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .mapping_end) {
            ev.deinit();
            break;
        }
        if (et != .scalar) {
            ev.deinit();
            return error.ExpectedScalarKey;
        }
        const key = try gpa.dupe(u8, ev.scalarValue());
        ev.deinit();
        defer gpa.free(key);
        const val = try nextScalarOrNull(parser, gpa);
        if (std.mem.eql(u8, key, "listen")) {
            listen = val;
        } else if (std.mem.eql(u8, key, "log_level")) {
            log_level = val;
        } else {
            if (val) |s| gpa.free(s);
        }
    }
    return .{
        .listen = listen orelse return error.MissingListen,
        .log_level = log_level orelse try gpa.dupe(u8, "info"),
    };
}

fn parseMihomoMapping(parser: *libyaml.Parser, gpa: std.mem.Allocator) !MihomoConfig {
    try expectEvent(parser, .mapping_start);
    var template: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var api: ?[]const u8 = null;
    var api_secret: ?[]const u8 = null;
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .mapping_end) {
            ev.deinit();
            break;
        }
        if (et != .scalar) {
            ev.deinit();
            return error.ExpectedScalarKey;
        }
        const key = try gpa.dupe(u8, ev.scalarValue());
        ev.deinit();
        defer gpa.free(key);
        const val = try nextScalarOrNull(parser, gpa);
        if (std.mem.eql(u8, key, "template")) {
            template = val;
        } else if (std.mem.eql(u8, key, "output")) {
            output = val;
        } else if (std.mem.eql(u8, key, "api")) {
            api = val;
        } else if (std.mem.eql(u8, key, "api_secret")) {
            api_secret = val;
        } else {
            if (val) |s| gpa.free(s);
        }
    }
    return .{
        .template = template orelse return error.MissingTemplate,
        .output = output orelse return error.MissingOutput,
        .api = api orelse return error.MissingApi,
        .api_secret = api_secret,
    };
}

fn parsePortMapping(parser: *libyaml.Parser, gpa: std.mem.Allocator) !PortConfig {
    try expectEvent(parser, .mapping_start);
    var range_start: ?u16 = null;
    var listen_addr: ?[]const u8 = null;
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .mapping_end) {
            ev.deinit();
            break;
        }
        if (et != .scalar) {
            ev.deinit();
            return error.ExpectedScalarKey;
        }
        const key = try gpa.dupe(u8, ev.scalarValue());
        ev.deinit();
        defer gpa.free(key);
        if (std.mem.eql(u8, key, "range_start")) {
            const val = try nextScalarOrNull(parser, gpa);
            defer if (val) |s| gpa.free(s);
            range_start = std.fmt.parseInt(u16, val orelse "0", 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, key, "listen_addr")) {
            listen_addr = try nextScalarOrNull(parser, gpa);
        } else {
            try skipValue(parser);
        }
    }
    return .{
        .range_start = range_start orelse return error.MissingRangeStart,
        .listen_addr = listen_addr orelse try gpa.dupe(u8, "127.0.0.1"),
    };
}

fn parseGroupsSequence(parser: *libyaml.Parser, gpa: std.mem.Allocator) ![]GroupConfig {
    try expectEvent(parser, .sequence_start);
    var groups = std.ArrayList(GroupConfig).empty;
    defer groups.deinit(gpa);
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .sequence_end) {
            ev.deinit();
            break;
        }
        if (et != .mapping_start) {
            ev.deinit();
            return error.ExpectedMapping;
        }
        ev.deinit();
        const group = try parseGroupMapping(parser, gpa);
        try groups.append(gpa, group);
    }
    return groups.toOwnedSlice(gpa);
}

fn parseGroupMapping(parser: *libyaml.Parser, gpa: std.mem.Allocator) !GroupConfig {
    var name: ?[]const u8 = null;
    var subscription: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var update_interval: u64 = 3600;
    var filter: ?[]const u8 = null;
    var exclude_filter: ?[]const u8 = null;
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .mapping_end) {
            ev.deinit();
            break;
        }
        if (et != .scalar) {
            ev.deinit();
            return error.ExpectedScalarKey;
        }
        const key = try gpa.dupe(u8, ev.scalarValue());
        ev.deinit();
        defer gpa.free(key);
        if (std.mem.eql(u8, key, "name")) {
            name = try nextScalarOrNull(parser, gpa);
        } else if (std.mem.eql(u8, key, "subscription")) {
            subscription = try nextScalarOrNull(parser, gpa);
        } else if (std.mem.eql(u8, key, "file")) {
            file = try nextScalarOrNull(parser, gpa);
        } else if (std.mem.eql(u8, key, "update_interval")) {
            const val = try nextScalarOrNull(parser, gpa);
            defer if (val) |s| gpa.free(s);
            update_interval = std.fmt.parseInt(u64, val orelse "3600", 10) catch 3600;
        } else if (std.mem.eql(u8, key, "filter")) {
            filter = try nextScalarOrNull(parser, gpa);
        } else if (std.mem.eql(u8, key, "exclude_filter")) {
            exclude_filter = try nextScalarOrNull(parser, gpa);
        } else {
            try skipValue(parser);
        }
    }
    return .{
        .name = name orelse return error.MissingGroupName,
        .subscription = subscription,
        .file = file,
        .update_interval = update_interval,
        .filter = filter,
        .exclude_filter = exclude_filter,
    };
}

pub const ServerConfig = struct {
    listen: []const u8,
    log_level: []const u8 = "info",
};

pub const MihomoConfig = struct {
    template: []const u8,
    output: []const u8,
    api: []const u8,
    api_secret: ?[]const u8 = null,
};

pub const PortConfig = struct {
    range_start: u16,
    listen_addr: []const u8 = "127.0.0.1",
};

pub const GroupConfig = struct {
    name: []const u8,
    subscription: ?[]const u8 = null,
    file: ?[]const u8 = null,
    update_interval: u64 = 3600,
    filter: ?[]const u8 = null,
    exclude_filter: ?[]const u8 = null,
};
