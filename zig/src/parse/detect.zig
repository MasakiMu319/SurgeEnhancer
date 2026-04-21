const std = @import("std");

pub const SubFormat = enum {
    clash_yaml,
    base64_uri,
    plain_uri,
};

pub fn detectFormat(body: []const u8) SubFormat {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "proxies:") or
        std.mem.startsWith(u8, trimmed, "port:") or
        std.mem.startsWith(u8, trimmed, "mixed-port:") or
        std.mem.indexOf(u8, trimmed, "\nproxies:") != null)
    {
        return .clash_yaml;
    }

    if (std.mem.startsWith(u8, trimmed, "ss://") or
        std.mem.startsWith(u8, trimmed, "ssr://") or
        std.mem.startsWith(u8, trimmed, "vmess://") or
        std.mem.startsWith(u8, trimmed, "vless://") or
        std.mem.startsWith(u8, trimmed, "trojan://") or
        std.mem.startsWith(u8, trimmed, "hysteria2://") or
        std.mem.startsWith(u8, trimmed, "hy2://") or
        std.mem.startsWith(u8, trimmed, "tuic://") or
        std.mem.startsWith(u8, trimmed, "anytls://"))
    {
        return .plain_uri;
    }

    return .base64_uri;
}
