
const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const document = @import("document.zig");

const TypeTag = types.TypeTag;
const Binary = types.Binary;
const ObjectId = types.ObjectId;
const Timestamp = types.Timestamp;
const Regex = types.Regex;
const Decimal128 = types.Decimal128;

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: usize,
    skip_utf8_validation: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Self {
        return .{
            .allocator = allocator,
            .data = data,
            .pos = 0,
            .skip_utf8_validation = false,
        };
    }

    pub fn setSkipUtf8Validation(self: *Self, skip: bool) void {
        self.skip_utf8_validation = skip;
    }

    pub fn decode(self: *Self, comptime T: type) errors.Error!T {
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            @compileError("Top-level BSON value must be a struct");
        }

        if (self.data.len < 5) return error.UnexpectedEof;
        const doc_size = self.readI32();
        if (doc_size < 5 or doc_size > self.data.len) {
            return error.MalformedDocument;
        }

        const doc_end = @as(usize, @intCast(doc_size));

        var result: T = undefined;
        primeStruct(&result);

        try self.decodeFields(T, &result, doc_end);

        if (self.pos >= self.data.len or self.data[self.pos] != 0) {
            return error.MalformedDocument;
        }

        return result;
    }

    fn decodeValue(self: *Self, comptime T: type, output: *T) errors.Error!void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => output.* = try self.decodeInt(T),
            .float => output.* = try self.decodeFloat(T),
            .bool => output.* = try self.decodeBool(),
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        if (ptr_info.child == u8) {
                            output.* = try self.decodeString();
                        } else {
                            output.* = try self.decodeArray(ptr_info.child);
                        }
                    },
                    else => @compileError("Unsupported pointer type"),
                }
            },
            .@"struct" => {
                if (T == ObjectId) {
                    output.* = try self.decodeObjectId();
                } else if (T == Binary) {
                    output.* = try self.decodeBinary();
                } else if (T == Timestamp) {
                    output.* = try self.decodeTimestamp();
                } else if (T == Regex) {
                    output.* = try self.decodeRegex();
                } else if (T == Decimal128) {
                    output.* = try self.decodeDecimal128();
                } else {
                    try self.decodeDocument(T, output);
                }
            },
            .optional => |opt_info| {
                if (self.pos < self.data.len) {
                    const tag_byte = self.data[self.pos];
                    if (tag_byte == @intFromEnum(TypeTag.null)) {
                        self.pos += 1;
                        _ = try self.readCString();
                        output.* = null;
                    } else {
                        var value: opt_info.child = undefined;
                        try self.decodeValue(opt_info.child, &value);
                        output.* = value;
                    }
                } else {
                    output.* = null;
                }
            },
            .@"enum" => {
                const str = try self.decodeString();
                defer self.allocator.free(str);
                output.* = std.meta.stringToEnum(T, str) orelse return error.TypeMismatch;
            },
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }

    fn decodeDocument(self: *Self, comptime T: type, output: *T) errors.Error!void {
        primeStruct(output);

        const doc_start = self.pos;
        const doc_size = self.readI32();
        const doc_end = doc_start + @as(usize, @intCast(doc_size));

        try self.decodeFields(T, output, doc_end);

        if (self.pos < self.data.len and self.data[self.pos] == 0) {
            self.pos += 1;
        }
    }

    fn decodeFields(self: *Self, comptime T: type, output: *T, doc_end: usize) errors.Error!void {
        const struct_info = @typeInfo(T).@"struct";

        while (self.pos < doc_end - 1) {
            const tag_byte = self.data[self.pos];
            if (tag_byte == 0) break;

            self.pos += 1;
            const field_name = try self.readCString();

            var found = false;
            inline for (struct_info.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    try self.decodeFieldValue(@TypeOf(@field(output.*, field.name)), tag_byte, &@field(output.*, field.name));
                    found = true;
                    break;
                }
            }

            if (!found) {
                try self.skipValue(tag_byte);
            }
        }
    }

    fn decodeFieldValue(self: *Self, comptime T: type, tag: u8, output: *T) errors.Error!void {
        const type_info = @typeInfo(T);

        if (type_info == .optional) {
            if (tag == @intFromEnum(TypeTag.null)) {
                output.* = null;
                return;
            }
            var child_val: type_info.optional.child = undefined;
            try self.decodeFieldValue(type_info.optional.child, tag, &child_val);
            output.* = child_val;
            return;
        }

        const wire_is_int32 = tag == @intFromEnum(TypeTag.int32);
        const wire_is_int64 = tag == @intFromEnum(TypeTag.int64);
        const wire_is_double = tag == @intFromEnum(TypeTag.double);
        const wire_is_numeric = wire_is_int32 or wire_is_int64 or wire_is_double;

        const expected_tag = try expectedTag(T);

        if (tag == expected_tag) {
            try self.decodeValue(T, output);
            return;
        }

        if (wire_is_numeric) {
            const raw_int: i64 = if (wire_is_int32) @as(i64, self.readI32()) else if (wire_is_int64) self.readI64() else 0;
            const raw_float: f64 = if (wire_is_double) @as(f64, @bitCast(self.readU64())) else 0;

            if (type_info == .int) {
                if (wire_is_double) {
                    output.* = @intFromFloat(raw_float);
                } else {
                    output.* = @intCast(raw_int);
                }
                return;
            } else if (type_info == .float) {
                if (wire_is_double) {
                    output.* = @floatCast(raw_float);
                } else {
                    output.* = @floatFromInt(raw_int);
                }
                return;
            }
        }

        return error.TypeMismatch;
    }

    fn expectedTag(comptime T: type) !u8 {
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int => |int_info| if (int_info.bits <= 32) @intFromEnum(TypeTag.int32) else @intFromEnum(TypeTag.int64),
            .float => @intFromEnum(TypeTag.double),
            .bool => @intFromEnum(TypeTag.boolean),
            .pointer => |ptr_info| if (ptr_info.child == u8) @intFromEnum(TypeTag.string) else @intFromEnum(TypeTag.array),
            .@"struct" => {
                if (T == ObjectId) return @intFromEnum(TypeTag.object_id);
                if (T == Binary) return @intFromEnum(TypeTag.binary);
                if (T == Timestamp) return @intFromEnum(TypeTag.timestamp);
                if (T == Regex) return @intFromEnum(TypeTag.regex);
                if (T == Decimal128) return @intFromEnum(TypeTag.decimal128);
                return @intFromEnum(TypeTag.document);
            },
            .optional => @intFromEnum(TypeTag.null),
            .@"enum" => @intFromEnum(TypeTag.string),
            else => error.TypeMismatch,
        };
    }

    fn decodeInt(self: *Self, comptime T: type) !T {
        const type_info = @typeInfo(T).int;

        if (type_info.bits <= 32) {
            return @as(T, @intCast(self.readI32()));
        } else {
            return @as(T, @intCast(self.readI64()));
        }
    }

    fn decodeFloat(self: *Self, comptime T: type) !T {
        const value = @as(f64, @bitCast(self.readU64()));
        return @as(T, @floatCast(value));
    }

    fn decodeBool(self: *Self) !bool {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const value = self.data[self.pos];
        self.pos += 1;
        return value != 0;
    }

    fn decodeString(self: *Self) ![]const u8 {
        const len = self.readI32();
        if (len < 1) return error.MalformedDocument;

        const str_len = @as(usize, @intCast(len - 1));
        if (self.pos + str_len + 1 > self.data.len) return error.UnexpectedEof;

        const str = self.data[self.pos .. self.pos + str_len];

        if (!self.skip_utf8_validation and !std.unicode.utf8ValidateSlice(str)) {
            return error.InvalidUtf8;
        }

        if (self.data[self.pos + str_len] != 0) {
            return error.MalformedDocument;
        }

        self.pos += str_len + 1;

        return try self.allocator.dupe(u8, str);
    }

    fn decodeObjectId(self: *Self) !ObjectId {
        if (self.pos + 12 > self.data.len) return error.UnexpectedEof;

        var bytes: [12]u8 = undefined;
        @memcpy(&bytes, self.data[self.pos .. self.pos + 12]);
        self.pos += 12;

        return ObjectId.fromBytes(bytes);
    }

    fn decodeBinary(self: *Self) !Binary {
        const len = self.readI32();
        if (len < 0) return error.MalformedDocument;

        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const subtype_byte = self.data[self.pos];
        self.pos += 1;

        const data_len = @as(usize, @intCast(len));
        if (self.pos + data_len > self.data.len) return error.UnexpectedEof;

        const data = try self.allocator.dupe(u8, self.data[self.pos .. self.pos + data_len]);
        self.pos += data_len;

        return Binary{
            .subtype = @enumFromInt(subtype_byte),
            .data = data,
        };
    }

    fn decodeTimestamp(self: *Self) !Timestamp {
        const value = @as(u64, @bitCast(self.readI64()));
        return Timestamp.fromU64(value);
    }

    fn decodeRegex(self: *Self) !Regex {
        const pattern = try self.readCStringAlloc();
        const options = try self.readCStringAlloc();

        return Regex{
            .pattern = pattern,
            .options = options,
        };
    }

    fn decodeDecimal128(self: *Self) !Decimal128 {
        if (self.pos + 16 > self.data.len) return error.UnexpectedEof;

        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, self.data[self.pos .. self.pos + 16]);
        self.pos += 16;

        return Decimal128.fromBytes(bytes);
    }

    fn decodeArray(self: *Self, comptime Child: type) ![]Child {
        const array_start = self.pos;
        const array_size = self.readI32();
        const array_end = array_start + @as(usize, @intCast(array_size));

        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(self.allocator);

        while (self.pos < array_end - 1) {
            const tag_byte = self.data[self.pos];
            if (tag_byte == 0) break;

            self.pos += 1;

            _ = try self.readCString();

            var item: Child = undefined;
            try self.decodeFieldValue(Child, tag_byte, &item);
            try items.append(self.allocator, item);
        }

        if (self.pos < self.data.len and self.data[self.pos] == 0) {
            self.pos += 1;
        }

        return try items.toOwnedSlice(self.allocator);
    }

    fn skipValue(self: *Self, tag: u8) !void {
        return document.skipValueInData(self.data, &self.pos, tag);
    }

    fn readI32(self: *Self) i32 {
        const value = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    fn readI64(self: *Self) i64 {
        const value = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    fn readU64(self: *Self) u64 {
        const value = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }

    fn readCString(self: *Self) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != 0) {
            self.pos += 1;
        }

        if (self.pos >= self.data.len) return error.UnexpectedEof;

        const str = self.data[start..self.pos];
        self.pos += 1;

        return str;
    }

    fn readCStringAlloc(self: *Self) ![]const u8 {
        const str = try self.readCString();
        return try self.allocator.dupe(u8, str);
    }
};

fn primeStruct(out: anytype) void {
    const T = @TypeOf(out.*);
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    inline for (info.@"struct".fields) |f| {
        if (f.default_value_ptr) |dv| {
            @field(out.*, f.name) = @as(*const f.type, @ptrCast(@alignCast(dv))).*;
        } else {
            const fi = @typeInfo(f.type);
            switch (fi) {
                .pointer => |p| {
                    if (p.size == .slice) {
                        @field(out.*, f.name) = &[_]p.child{};
                    }
                },
                .int => @field(out.*, f.name) = 0,
                .float => @field(out.*, f.name) = 0.0,
                .bool => @field(out.*, f.name) = false,
                .optional => @field(out.*, f.name) = null,
                .@"struct" => primeStruct(&@field(out.*, f.name)),
                else => {},
            }
        }
    }
}
