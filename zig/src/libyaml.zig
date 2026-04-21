const std = @import("std");

const c = @cImport({
    @cInclude("yaml.h");
});

pub const Parser = struct {
    raw: c.yaml_parser_t,

    pub fn init() !Parser {
        var p: c.yaml_parser_t = undefined;
        if (c.yaml_parser_initialize(&p) == 0) return error.YamlParserInitFailed;
        return .{ .raw = p };
    }

    pub fn deinit(self: *Parser) void {
        c.yaml_parser_delete(&self.raw);
    }

    pub fn setInputString(self: *Parser, input: []const u8) void {
        c.yaml_parser_set_input_string(&self.raw, input.ptr, input.len);
    }

    pub fn nextEvent(self: *Parser) !Event {
        var event: c.yaml_event_t = undefined;
        if (c.yaml_parser_parse(&self.raw, &event) == 0) {
            return error.YamlParseError;
        }
        return Event{ .raw = event };
    }
};

pub const Event = struct {
    raw: c.yaml_event_t,

    pub fn deinit(self: *Event) void {
        c.yaml_event_delete(&self.raw);
    }

    pub fn eventType(self: *const Event) EventType {
        return switch (self.raw.type) {
            c.YAML_NO_EVENT => .no,
            c.YAML_STREAM_START_EVENT => .stream_start,
            c.YAML_STREAM_END_EVENT => .stream_end,
            c.YAML_DOCUMENT_START_EVENT => .document_start,
            c.YAML_DOCUMENT_END_EVENT => .document_end,
            c.YAML_SEQUENCE_START_EVENT => .sequence_start,
            c.YAML_SEQUENCE_END_EVENT => .sequence_end,
            c.YAML_MAPPING_START_EVENT => .mapping_start,
            c.YAML_MAPPING_END_EVENT => .mapping_end,
            c.YAML_ALIAS_EVENT => .alias,
            c.YAML_SCALAR_EVENT => .scalar,
            else => .unknown,
        };
    }

    pub fn scalarValue(self: *const Event) []const u8 {
        const s = self.raw.data.scalar.value;
        const len = self.raw.data.scalar.length;
        return s[0..len];
    }
};

pub const EventType = enum {
    no,
    stream_start,
    stream_end,
    document_start,
    document_end,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
    alias,
    scalar,
    unknown,
};

/// Skip events until we find the key "proxies", then enter its sequence.
pub fn findProxiesSequence(parser: *Parser) !void {
    while (true) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .stream_end or et == .document_end) {
            ev.deinit();
            return error.ProxiesNotFound;
        }
        if (et == .scalar and std.mem.eql(u8, ev.scalarValue(), "proxies")) {
            ev.deinit();
            // Next should be sequence_start
            var seq = try parser.nextEvent();
            if (seq.eventType() != .sequence_start) {
                seq.deinit();
                return error.ExpectedSequence;
            }
            seq.deinit();
            return;
        }
        ev.deinit();
    }
}

/// Skip events until after the next mapping_end at the current level.
pub fn skipMapping(parser: *Parser) !void {
    var depth: usize = 1;
    while (depth > 0) {
        var ev = try parser.nextEvent();
        const et = ev.eventType();
        if (et == .mapping_start) depth += 1;
        if (et == .mapping_end) depth -= 1;
        ev.deinit();
    }
}

/// Read the next scalar value from the parser.
pub fn nextScalar(parser: *Parser) ![]const u8 {
    var ev = try parser.nextEvent();
    if (ev.eventType() != .scalar) {
        ev.deinit();
        return error.ExpectedScalar;
    }
    const val = ev.scalarValue();
    ev.deinit();
    return val;
}
