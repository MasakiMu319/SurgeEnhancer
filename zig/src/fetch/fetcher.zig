const std = @import("std");
const config = @import("../config.zig");
const model = @import("../model.zig");
const parse = @import("../parse/detect.zig");
const clash = @import("../parse/clash.zig");
const base64 = @import("../parse/base64.zig");

fn getCacheDir(gpa: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("HOME")) |home| {
        return std.fmt.allocPrint(gpa, "{s}/Library/Caches/surge-enhancer", .{home});
    }
    return gpa.dupe(u8, ".cache/surge-enhancer");
}

pub fn fetchGroup(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    group: config.GroupConfig,
) ![]model.ProxyNode {
    const body = if (group.subscription) |url| blk: {
        std.log.info("fetching subscription: {s}", .{url});
        const fetched = httpGetText(gpa, io, client, url) catch |err| {
            std.log.warn("fetch failed for '{s}': {s}, trying cache", .{ group.name, @errorName(err) });
            break :blk loadCache(gpa, io, group.name) orelse return err;
        };
        break :blk fetched;
    } else if (group.file) |path| blk: {
        std.log.info("reading local file: {s}", .{path});
        break :blk try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    } else {
        return error.GroupMissingSource;
    };
    defer gpa.free(body);

    const format = parse.detectFormat(body);
    var nodes = switch (format) {
        .clash_yaml => try clash.parseClashYaml(gpa, body, group.name),
        .base64_uri => try base64.parseBase64Uris(gpa, body, group.name),
        .plain_uri => try base64.parseUriLines(gpa, body, group.name),
    };
    errdefer {
        for (nodes) |*n| n.deinit(gpa);
        gpa.free(nodes);
    }

    // Cache only after successful parse
    if (group.subscription != null) saveCache(gpa, io, group.name, body);

    // Apply filters
    if (group.filter) |pattern| {
        const regex = try compileRegex(gpa, pattern);
        defer regex.deinit();
        var filtered = std.ArrayList(model.ProxyNode).empty;
        errdefer {
            for (filtered.items) |*n| n.deinit(gpa);
            filtered.deinit(gpa);
        }
        for (nodes) |*node| {
            if (regex.isMatch(node.name)) {
                try filtered.append(gpa, node.*);
            } else {
                node.deinit(gpa);
            }
        }
        gpa.free(nodes);
        nodes = try filtered.toOwnedSlice(gpa);
    }

    if (group.exclude_filter) |pattern| {
        const regex = try compileRegex(gpa, pattern);
        defer regex.deinit();
        var filtered = std.ArrayList(model.ProxyNode).empty;
        errdefer {
            for (filtered.items) |*n| n.deinit(gpa);
            filtered.deinit(gpa);
        }
        for (nodes) |*node| {
            if (!regex.isMatch(node.name)) {
                try filtered.append(gpa, node.*);
            } else {
                node.deinit(gpa);
            }
        }
        gpa.free(nodes);
        nodes = try filtered.toOwnedSlice(gpa);
    }

    std.log.info("group '{s}': {d} nodes after filtering", .{ group.name, nodes.len });
    return nodes;
}

fn httpGetText(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, url: []const u8) ![]const u8 {
    _ = io;
    var req = try client.request(.GET, try std.Uri.parse(url), .{});
    defer req.deinit();
    req.headers.accept_encoding = .{ .override = "identity" };
    req.headers.user_agent = .{ .override = "clash-verge/v2.2.3" };
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    var rdr = response.reader(&.{});
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try rdr.appendRemainingUnlimited(gpa, &body);
    return body.toOwnedSlice(gpa);
}

fn cachePath(gpa: std.mem.Allocator, group_name: []const u8) ![]const u8 {
    const dir = try getCacheDir(gpa);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/{s}.sub", .{ dir, group_name });
}

fn saveCache(gpa: std.mem.Allocator, io: std.Io, group_name: []const u8, data: []const u8) void {
    const dir = getCacheDir(gpa) catch return;
    defer gpa.free(dir);
    const path = cachePath(gpa, group_name) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| {
        std.log.warn("failed to write cache for '{s}': {s}", .{ group_name, @errorName(err) });
    };
    std.log.info("cached subscription for '{s}'", .{group_name});
}

fn loadCache(gpa: std.mem.Allocator, io: std.Io, group_name: []const u8) ?[]const u8 {
    const path = cachePath(gpa, group_name) catch return null;
    defer gpa.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return null;
    std.log.info("loaded subscription from cache for '{s}'", .{group_name});
    return data;
}

const pcre2 = @import("../pcre2.zig");

fn compileRegex(gpa: std.mem.Allocator, pattern: []const u8) !pcre2.Regex {
    return pcre2.Regex.init(gpa, pattern);
}
