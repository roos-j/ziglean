//! Allocation-free recognition of the exporter's canonical expression records.
//! This is a strict subset of JSON: any other layout goes to the full parser.
const std = @import("std");

pub const Kind = enum { app, bvar, sort, cnst, lam, pi, letE, proj, succ, max, imax, param, name_str, name_num };
pub const Record = struct {
    kind: Kind,
    id: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    universes: [16]u32 = undefined,
    universe_count: u8 = 0,
};

const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,

    inline fn take(self: *Cursor, comptime literal: []const u8) bool {
        if (!std.mem.startsWith(u8, self.bytes[self.position..], literal)) return false;
        self.position += literal.len;
        return true;
    }

    inline fn number(self: *Cursor) ?u32 {
        const start = self.position;
        var value: u64 = 0;
        // Adapted from nano-lean's MIT-licensed SWAR scanner. See notices.
        if (self.bytes.len - start >= 8) {
            const lanes: u64 = 0x0101010101010101;
            const word = std.mem.readInt(u64, self.bytes[start..][0..8], .little) ^ (0x30 * lanes);
            const invalid = ((word +% (0x76 * lanes)) | word) & (0x80 * lanes);
            const count: usize = @min(@ctz(invalid) / 8, 8);
            if (count == 0) return null;
            const aligned = word << @as(u6, @intCast((8 - count) * 8));
            const pairs = aligned *% 10 +% (aligned >> 8);
            value = ((pairs & 0x000000ff000000ff) *% 0x000f424000000064 +% (((pairs >> 16) & 0x000000ff000000ff) *% 0x0000271000000001)) >> 32;
            self.position += count;
        }
        while (self.position < self.bytes.len) {
            const digit = self.bytes[self.position] -% '0';
            if (digit > 9) break;
            if (self.position - start == 10) return null;
            value = value * 10 + digit;
            self.position += 1;
        }
        if (self.position == start or value > std.math.maxInt(u32)) return null;
        if (self.position > start + 1 and self.bytes[start] == '0') return null;
        return @intCast(value);
    }
};

pub inline fn scan(bytes: []const u8) ?Record {
    var cur: Cursor = .{ .bytes = std.mem.trimRight(u8, bytes, "\r \t") };
    var result: Record = undefined;
    if (cur.take("{\"app\":{\"arg\":")) {
        result = .{ .kind = .app };
        result.b = cur.number() orelse return null;
        if (!cur.take(",\"fn\":")) return null;
        result.a = cur.number() orelse return null;
        if (!cur.take("},\"ie\":")) return null;
    } else if (cur.take("{\"bvar\":")) {
        result = .{ .kind = .bvar };
        result.a = cur.number() orelse return null;
        if (!cur.take(",\"ie\":")) return null;
    } else if (cur.take("{\"const\":{\"name\":")) {
        result = .{ .kind = .cnst };
        result.a = cur.number() orelse return null;
        if (!cur.take(",\"us\":[")) return null;
        if (!cur.take("]")) {
            while (true) {
                if (result.universe_count == result.universes.len) return null;
                result.universes[result.universe_count] = cur.number() orelse return null;
                result.universe_count += 1;
                if (cur.take("]")) break;
                if (!cur.take(",")) return null;
            }
        }
        if (!cur.take("},\"ie\":")) return null;
    } else if (cur.take("{\"forallE\":{\"binderInfo\":\"")) {
        result = .{ .kind = .pi };
        if (!binding(&cur, &result) or !cur.take(",\"ie\":")) return null;
    } else if (cur.take("{\"lam\":{\"binderInfo\":\"")) {
        result = .{ .kind = .lam };
        if (!binding(&cur, &result) or !cur.take(",\"ie\":")) return null;
    } else if (cur.take("{\"ie\":")) {
        result = .{ .kind = .sort };
        result.id = cur.number() orelse return null;
        if (cur.take(",\"sort\":")) {
            result.a = cur.number() orelse return null;
        } else if (cur.take(",\"lam\":{\"binderInfo\":\"")) {
            result.kind = .lam;
            if (!binding(&cur, &result)) return null;
        } else if (cur.take(",\"letE\":{\"body\":")) {
            result.kind = .letE;
            result.c = cur.number() orelse return null;
            if (!cur.take(",\"name\":")) return null;
            result.d = cur.number() orelse return null;
            if (!cur.take(",\"nondep\":") or (!cur.take("false") and !cur.take("true"))) return null;
            if (!cur.take(",\"type\":")) return null;
            result.a = cur.number() orelse return null;
            if (!cur.take(",\"value\":")) return null;
            result.b = cur.number() orelse return null;
            if (!cur.take("}")) return null;
        } else if (cur.take(",\"proj\":{\"idx\":")) {
            result.kind = .proj;
            result.b = cur.number() orelse return null;
            if (!cur.take(",\"struct\":")) return null;
            result.c = cur.number() orelse return null;
            if (!cur.take(",\"typeName\":")) return null;
            result.a = cur.number() orelse return null;
            if (!cur.take("}")) return null;
        } else return null;
        if (!cur.take("}") or cur.position != cur.bytes.len) return null;
        return result;
    } else if (cur.take("{\"il\":")) {
        result = .{ .kind = .succ };
        result.id = cur.number() orelse return null;
        if (cur.take(",\"succ\":")) {
            result.a = cur.number() orelse return null;
        } else if (cur.take(",\"param\":")) {
            result.kind = .param;
            result.a = cur.number() orelse return null;
        } else {
            if (cur.take(",\"max\":[")) {
                result.kind = .max;
            } else if (cur.take(",\"imax\":[")) {
                result.kind = .imax;
            } else return null;
            result.a = cur.number() orelse return null;
            if (!cur.take(",")) return null;
            result.b = cur.number() orelse return null;
            if (!cur.take("]")) return null;
        }
        if (!cur.take("}") or cur.position != cur.bytes.len) return null;
        return result;
    } else if (cur.take("{\"in\":")) {
        result = .{ .kind = .name_str };
        result.id = cur.number() orelse return null;
        if (cur.take(",\"str\":{\"pre\":")) {
            result.a = cur.number() orelse return null;
            if (!cur.take(",\"str\":\"")) return null;
            const start = cur.position;
            const length = std.mem.indexOfScalar(u8, cur.bytes[start..], '"') orelse return null;
            const text = cur.bytes[start..][0..length];
            for (text) |byte| if (byte == '\\' or byte < 0x20) return null;
            if (!std.unicode.utf8ValidateSlice(text)) return null;
            result.b = @intCast(start);
            result.c = @intCast(start + length);
            cur.position += length + 1;
        } else if (cur.take(",\"num\":{\"i\":")) {
            result.kind = .name_num;
            result.b = cur.number() orelse return null;
            if (!cur.take(",\"pre\":")) return null;
            result.a = cur.number() orelse return null;
        } else return null;
        if (!cur.take("}}") or cur.position != cur.bytes.len) return null;
        return result;
    } else return null;
    result.id = cur.number() orelse return null;
    if (!cur.take("}") or cur.position != cur.bytes.len) return null;
    return result;
}

fn binding(cur: *Cursor, result: *Record) bool {
    if (!cur.take("default\"") and !cur.take("implicit\"") and !cur.take("strictImplicit\"") and !cur.take("instImplicit\"")) return false;
    if (!cur.take(",\"body\":")) return false;
    result.b = cur.number() orelse return false;
    if (!cur.take(",\"name\":")) return false;
    result.c = cur.number() orelse return false;
    if (!cur.take(",\"type\":")) return false;
    result.a = cur.number() orelse return false;
    return cur.take("}");
}
