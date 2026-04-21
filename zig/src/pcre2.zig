const std = @import("std");

const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cDefine("PCRE2_STATIC", "1");
    @cInclude("pcre2.h");
});

pub const Regex = struct {
    re: *anyopaque,
    match_data: *anyopaque,

    pub fn init(_: std.mem.Allocator, pattern: []const u8) !Regex {
        var errorcode: c_int = 0;
        var erroffset: usize = 0;
        const re = c.pcre2_compile_8(
            @ptrCast(pattern.ptr),
            pattern.len,
            0,
            &errorcode,
            &erroffset,
            null,
        );
        if (re == null) return error.RegexCompileFailed;
        const match_data = c.pcre2_match_data_create_from_pattern_8(re, null);
        if (match_data == null) {
            c.pcre2_code_free_8(re);
            return error.RegexMatchDataCreateFailed;
        }
        return .{ .re = @ptrCast(re.?), .match_data = @ptrCast(match_data.?) };
    }

    pub fn deinit(self: Regex) void {
        c.pcre2_match_data_free_8(@ptrCast(@alignCast(self.match_data)));
        c.pcre2_code_free_8(@ptrCast(@alignCast(self.re)));
    }

    pub fn isMatch(self: Regex, text: []const u8) bool {
        const rc = c.pcre2_match_8(
            @ptrCast(@alignCast(self.re)),
            @ptrCast(text.ptr),
            text.len,
            0,
            0,
            @ptrCast(@alignCast(self.match_data)),
            null,
        );
        return rc >= 0;
    }
};
