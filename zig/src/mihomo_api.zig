const std = @import("std");
const config = @import("config.zig");

fn percentEncode(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(gpa);
}

fn apiUrl(gpa: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ trimmed, path });
}

fn addAuthHeader(req: *std.http.Client.Request, mihomo: config.MihomoConfig, buf: *[256]u8) void {
    if (mihomo.api_secret) |secret| {
        const auth = std.fmt.bufPrint(buf, "Bearer {s}", .{secret}) catch return;
        req.headers.authorization = .{ .override = auth };
    }
}

pub fn reloadConfig(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, mihomo: config.MihomoConfig) !void {
    _ = io;
    const url = try apiUrl(gpa, mihomo.api, "/configs?force=true");
    defer gpa.free(url);

    var req = try client.request(.PUT, try std.Uri.parse(url), .{});
    var auth_buf: [256]u8 = undefined;
    addAuthHeader(&req, mihomo, &auth_buf);
    defer req.deinit();

    const body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\"}}", .{mihomo.output});
    defer gpa.free(body);

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    if (response.head.status.class() != .success) {
        return error.MihomoReloadFailed;
    }
}

pub fn testDelay(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    mihomo: config.MihomoConfig,
    node_name: []const u8,
) !std.json.Value {
    _ = io;
    const encoded = try percentEncode(gpa, node_name);
    defer gpa.free(encoded);
    const url = try apiUrl(gpa, mihomo.api, "/proxies/");
    defer gpa.free(url);
    const full = try std.fmt.allocPrint(gpa, "{s}{s}/delay?timeout=5000&url=http://www.gstatic.com/generate_204", .{ url, encoded });
    defer gpa.free(full);

    var req = try client.request(.GET, try std.Uri.parse(full), .{});
    var auth_buf: [256]u8 = undefined;
    addAuthHeader(&req, mihomo, &auth_buf);
    defer req.deinit();
    try req.sendBodiless();

    var response = try req.receiveHead(&.{});
    var rdr = response.reader(&.{});
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try rdr.appendRemainingUnlimited(gpa, &body);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body.items, .{});
    defer parsed.deinit();
    return try cloneJsonValue(gpa, parsed.value);
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
            for (arr.items) |item| {
                try new.append(try cloneJsonValue(gpa, item));
            }
            break :blk .{ .array = new };
        },
        .object => |obj| blk: {
            var new = try std.json.ObjectMap.init(gpa, &.{}, &.{});
            var it = obj.iterator();
            while (it.next()) |entry| {
                try new.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), try cloneJsonValue(gpa, entry.value_ptr.*));
            }
            break :blk .{ .object = new };
        },
    };
}
