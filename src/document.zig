
const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

const TypeTag = types.TypeTag;
const Binary = types.Binary;
const ObjectId = types.ObjectId;
const Timestamp = types.Timestamp;
const Regex = types.Regex;
const Decimal128 = types.Decimal128;

pub const Value = union(enum) {
    double: f64,
    string: []const u8,
    document: BsonDocument,
    array: BsonArray,
    binary: Binary,
    object_id: ObjectId,
    boolean: bool,
    datetime: i64,
    null: void,
    regex: Regex,
    int32: i32,
    timestamp: Timestamp,
    int64: i64,
    decimal128: Decimal128,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .document => |*doc| doc.deinit(),
            .array => |*arr| arr.deinit(),
            .binary => |bin| allocator.free(bin.data),
            .regex => |r| {
                allocator.free(r.pattern);
                allocator.free(r.options);
            },
            else => {},
        }
    }
};

pub fn skipValueInData(data: []const u8, pos: *usize, tag: u8) !void {
    const type_tag = @as(TypeTag, @enumFromInt(tag));

    switch (type_tag) {
        .double => pos.* += 8,
        .string => {
            const str_len = readI32At(data, pos);
            pos.* += @as(usize, @intCast(str_len));
        },
        .document, .array => {
            const size = readI32At(data, pos);
            pos.* += @as(usize, @intCast(size)) - 4;
        },
        .binary => {
            const data_len = readI32At(data, pos);
            pos.* += 1 + @as(usize, @intCast(data_len));
        },
        .object_id => pos.* += 12,
        .boolean => pos.* += 1,
        .datetime => pos.* += 8,
        .null => {},
        .regex => {
            try skipCStringAt(data, pos);
            try skipCStringAt(data, pos);
        },
        .int32 => pos.* += 4,
        .timestamp, .int64 => pos.* += 8,
        .decimal128 => pos.* += 16,
        else => return error.InvalidType,
    }
}

fn readI32At(data: []const u8, pos: *usize) i32 {
    const value = std.mem.readInt(i32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return value;
}

fn skipCStringAt(data: []const u8, pos: *usize) !void {
    while (pos.* < data.len and data[pos.*] != 0) {
        pos.* += 1;
    }
    if (pos.* >= data.len) return error.UnexpectedEof;
    pos.* += 1;
}

pub const BsonDocument = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    owned: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8, owned: bool) !Self {
        if (data.len < 5) return error.UnexpectedEof;
        const doc_size = std.mem.readInt(i32, data[0..4], .little);
        if (doc_size < 5 or doc_size > data.len) {
            return error.MalformedDocument;
        }

        return .{
            .allocator = allocator,
            .data = data,
            .owned = owned,
        };
    }

    pub fn initCopy(allocator: std.mem.Allocator, data: []const u8) !Self {
        const copy = try allocator.dupe(u8, data);
        return try init(allocator, copy, true);
    }

    pub fn deinit(self: *Self) void {
        if (self.owned) {
            self.allocator.free(self.data);
        }
    }

    pub fn empty(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .data = &[_]u8{ 5, 0, 0, 0, 0 },
            .owned = false,
        };
    }

    pub fn put(self: *Self, name: []const u8, value: Value) !void {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        if (self.data.len >= 5) {
            const doc_size = std.mem.readInt(i32, self.data[0..4], .little);
            const content_end = @as(usize, @intCast(doc_size)) - 1;
            try buf.appendSlice(self.allocator, self.data[0..content_end]);
        } else {
            try buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });
        }

        const tag: u8 = switch (value) {
            .double => @intFromEnum(TypeTag.double),
            .string => @intFromEnum(TypeTag.string),
            .document => @intFromEnum(TypeTag.document),
            .array => @intFromEnum(TypeTag.array),
            .binary => @intFromEnum(TypeTag.binary),
            .object_id => @intFromEnum(TypeTag.object_id),
            .boolean => @intFromEnum(TypeTag.boolean),
            .datetime => @intFromEnum(TypeTag.datetime),
            .null => @intFromEnum(TypeTag.null),
            .regex => @intFromEnum(TypeTag.regex),
            .int32 => @intFromEnum(TypeTag.int32),
            .timestamp => @intFromEnum(TypeTag.timestamp),
            .int64 => @intFromEnum(TypeTag.int64),
            .decimal128 => @intFromEnum(TypeTag.decimal128),
        };
        try buf.append(self.allocator, tag);

        try buf.appendSlice(self.allocator, name);
        try buf.append(self.allocator, 0);

        switch (value) {
            .double => |v| {
                const bits: u64 = @bitCast(v);
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(u64, bits)));
            },
            .string => |v| {
                const len: i32 = @intCast(v.len + 1);
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i32, len)));
                try buf.appendSlice(self.allocator, v);
                try buf.append(self.allocator, 0);
            },
            .document => |v| {
                try buf.appendSlice(self.allocator, v.data);
            },
            .array => |v| {
                try buf.appendSlice(self.allocator, v.data);
            },
            .int32 => |v| {
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i32, v)));
            },
            .int64 => |v| {
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i64, v)));
            },
            .boolean => |v| {
                try buf.append(self.allocator, if (v) 1 else 0);
            },
            .null => {},
            .datetime => |v| {
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i64, v)));
            },
            .object_id => |v| {
                try buf.appendSlice(self.allocator, &v.bytes);
            },
            .binary => |v| {
                const len: i32 = @intCast(v.data.len);
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i32, len)));
                try buf.append(self.allocator, @intFromEnum(v.subtype));
                try buf.appendSlice(self.allocator, v.data);
            },
            .regex => |v| {
                try buf.appendSlice(self.allocator, v.pattern);
                try buf.append(self.allocator, 0);
                try buf.appendSlice(self.allocator, v.options);
                try buf.append(self.allocator, 0);
            },
            .timestamp => |v| {
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(u32, v.increment)));
                try buf.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(u32, v.timestamp)));
            },
            .decimal128 => |v| {
                try buf.appendSlice(self.allocator, &v.bytes);
            },
        }

        try buf.append(self.allocator, 0);

        const size: i32 = @intCast(buf.items.len);
        @memcpy(buf.items[0..4], std.mem.asBytes(&std.mem.nativeToLittle(i32, size)));

        if (self.owned) {
            self.allocator.free(self.data);
        }
        self.data = try buf.toOwnedSlice(self.allocator);
        self.owned = true;
    }

    pub fn putString(self: *Self, name: []const u8, value: []const u8) !void {
        try self.put(name, .{ .string = value });
    }

    pub fn putInt32(self: *Self, name: []const u8, value: i32) !void {
        try self.put(name, .{ .int32 = value });
    }

    pub fn putInt64(self: *Self, name: []const u8, value: i64) !void {
        try self.put(name, .{ .int64 = value });
    }

    pub fn putDouble(self: *Self, name: []const u8, value: f64) !void {
        try self.put(name, .{ .double = value });
    }

    pub fn putBool(self: *Self, name: []const u8, value: bool) !void {
        try self.put(name, .{ .boolean = value });
    }

    pub fn putNull(self: *Self, name: []const u8) !void {
        try self.put(name, .{ .null = {} });
    }

    pub fn putDocument(self: *Self, name: []const u8, doc: BsonDocument) !void {
        try self.put(name, .{ .document = doc });
    }

    pub fn putArray(self: *Self, name: []const u8, arr: BsonArray) !void {
        try self.put(name, .{ .array = arr });
    }

    pub fn toBytes(self: *const Self) []const u8 {
        return self.data;
    }

    pub fn getField(self: *const Self, field_name: []const u8) !?Value {
        var pos: usize = 4;
        const doc_size = std.mem.readInt(i32, self.data[0..4], .little);
        const doc_end = @as(usize, @intCast(doc_size));

        while (pos < doc_end - 1) {
            const tag_byte = self.data[pos];
            if (tag_byte == 0) break;

            pos += 1;
            const name = try self.readCString(&pos);

            if (std.mem.eql(u8, name, field_name)) {
                return try self.readValue(tag_byte, &pos);
            } else {
                try self.skipValue(tag_byte, &pos);
            }
        }

        return null;
    }

    pub fn getNestedField(self: *const Self, field_path: []const u8) !?Value {
        const dot_pos = std.mem.indexOfScalar(u8, field_path, '.') orelse
            return self.getField(field_path);

        const parent_name = field_path[0..dot_pos];
        const rest = field_path[dot_pos + 1 ..];

        if (try self.getField(parent_name)) |parent_val| {
            switch (parent_val) {
                .document => |subdoc| return subdoc.getNestedField(rest),
                else => return null,
            }
        }
        return null;
    }

    fn getAs(self: *const Self, comptime tag: std.meta.Tag(Value), comptime T: type, field_name: []const u8) !?T {
        if (try self.getField(field_name)) |value| {
            switch (value) {
                tag => |v| return v,
                else => return error.TypeMismatch,
            }
        }
        return null;
    }

    pub fn getString(self: *const Self, field_name: []const u8) !?[]const u8 {
        return self.getAs(.string, []const u8, field_name);
    }

    pub fn getInt32(self: *const Self, field_name: []const u8) !?i32 {
        if (try self.getField(field_name)) |value| {
            switch (value) {
                .int32 => |i| return i,
                .int64 => |i| return @intCast(i),
                else => return error.TypeMismatch,
            }
        }
        return null;
    }

    pub fn getInt64(self: *const Self, field_name: []const u8) !?i64 {
        if (try self.getField(field_name)) |value| {
            switch (value) {
                .int64 => |i| return i,
                .int32 => |i| return @intCast(i),
                else => return error.TypeMismatch,
            }
        }
        return null;
    }

    pub fn getBool(self: *const Self, field_name: []const u8) !?bool {
        return self.getAs(.boolean, bool, field_name);
    }

    pub fn getDouble(self: *const Self, field_name: []const u8) !?f64 {
        return self.getAs(.double, f64, field_name);
    }

    pub fn getObjectId(self: *const Self, field_name: []const u8) !?ObjectId {
        return self.getAs(.object_id, ObjectId, field_name);
    }

    pub fn getDocument(self: *const Self, field_name: []const u8) !?BsonDocument {
        return self.getAs(.document, BsonDocument, field_name);
    }

    pub fn getArray(self: *const Self, field_name: []const u8) !?BsonArray {
        return self.getAs(.array, BsonArray, field_name);
    }

    pub fn getFieldNames(self: *const Self, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }

        var pos: usize = 4;
        const doc_size = std.mem.readInt(i32, self.data[0..4], .little);
        const doc_end = @as(usize, @intCast(doc_size));

        while (pos < doc_end - 1) {
            const tag_byte = self.data[pos];
            if (tag_byte == 0) break;

            pos += 1;
            const name = try self.readCString(&pos);
            const name_copy = try allocator.dupe(u8, name);
            try names.append(allocator, name_copy);

            try self.skipValue(tag_byte, &pos);
        }

        return try names.toOwnedSlice(allocator);
    }

    fn readValue(self: *const Self, tag: u8, pos: *usize) !Value {
        const type_tag = @as(TypeTag, @enumFromInt(tag));

        return switch (type_tag) {
            .double => Value{ .double = self.readF64(pos) },
            .string => Value{ .string = try self.readStringAlloc(pos) },
            .document => Value{ .document = try self.readDocument(pos) },
            .array => Value{ .array = try self.readArray(pos) },
            .binary => Value{ .binary = try self.readBinary(pos) },
            .object_id => Value{ .object_id = try self.readObjectId(pos) },
            .boolean => Value{ .boolean = self.readBool(pos) },
            .datetime => Value{ .datetime = self.readI64(pos) },
            .null => Value{ .null = {} },
            .regex => Value{ .regex = try self.readRegex(pos) },
            .int32 => Value{ .int32 = self.readI32(pos) },
            .timestamp => Value{ .timestamp = Timestamp.fromU64(@bitCast(self.readI64(pos))) },
            .int64 => Value{ .int64 = self.readI64(pos) },
            .decimal128 => Value{ .decimal128 = try self.readDecimal128(pos) },
            else => error.InvalidType,
        };
    }

    fn readCString(self: *const Self, pos: *usize) ![]const u8 {
        const start = pos.*;
        while (pos.* < self.data.len and self.data[pos.*] != 0) {
            pos.* += 1;
        }

        if (pos.* >= self.data.len) return error.UnexpectedEof;

        const str = self.data[start..pos.*];
        pos.* += 1;

        return str;
    }

    fn readI32(self: *const Self, pos: *usize) i32 {
        const value = std.mem.readInt(i32, self.data[pos.*..][0..4], .little);
        pos.* += 4;
        return value;
    }

    fn readI64(self: *const Self, pos: *usize) i64 {
        const value = std.mem.readInt(i64, self.data[pos.*..][0..8], .little);
        pos.* += 8;
        return value;
    }

    fn readF64(self: *const Self, pos: *usize) f64 {
        const value = std.mem.readInt(u64, self.data[pos.*..][0..8], .little);
        pos.* += 8;
        return @bitCast(value);
    }

    fn readBool(self: *const Self, pos: *usize) bool {
        const value = self.data[pos.*] != 0;
        pos.* += 1;
        return value;
    }

    fn readStringAlloc(self: *const Self, pos: *usize) ![]const u8 {
        const len = self.readI32(pos);
        if (len < 1) return error.MalformedDocument;

        const str_len = @as(usize, @intCast(len - 1));
        if (pos.* + str_len + 1 > self.data.len) return error.UnexpectedEof;

        const str = self.data[pos.* .. pos.* + str_len];
        pos.* += str_len + 1;

        return try self.allocator.dupe(u8, str);
    }

    fn readObjectId(self: *const Self, pos: *usize) !ObjectId {
        if (pos.* + 12 > self.data.len) return error.UnexpectedEof;

        var bytes: [12]u8 = undefined;
        @memcpy(&bytes, self.data[pos.* .. pos.* + 12]);
        pos.* += 12;

        return ObjectId.fromBytes(bytes);
    }

    fn readBinary(self: *const Self, pos: *usize) !Binary {
        const len = self.readI32(pos);
        if (len < 0) return error.MalformedDocument;

        if (pos.* >= self.data.len) return error.UnexpectedEof;
        const subtype_byte = self.data[pos.*];
        pos.* += 1;

        const data_len = @as(usize, @intCast(len));
        if (pos.* + data_len > self.data.len) return error.UnexpectedEof;

        const data = try self.allocator.dupe(u8, self.data[pos.* .. pos.* + data_len]);
        pos.* += data_len;

        return Binary{
            .subtype = @enumFromInt(subtype_byte),
            .data = data,
        };
    }

    fn readRegex(self: *const Self, pos: *usize) !Regex {
        const pattern = try self.readCString(pos);
        const options = try self.readCString(pos);

        return Regex{
            .pattern = try self.allocator.dupe(u8, pattern),
            .options = try self.allocator.dupe(u8, options),
        };
    }

    fn readDecimal128(self: *const Self, pos: *usize) !Decimal128 {
        if (pos.* + 16 > self.data.len) return error.UnexpectedEof;

        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, self.data[pos.* .. pos.* + 16]);
        pos.* += 16;

        return Decimal128.fromBytes(bytes);
    }

    fn readDocument(self: *const Self, pos: *usize) !BsonDocument {
        const doc_start = pos.*;
        const doc_size = self.readI32(pos);
        const doc_data = self.data[doc_start .. doc_start + @as(usize, @intCast(doc_size))];

        pos.* = doc_start + @as(usize, @intCast(doc_size));

        return try BsonDocument.init(self.allocator, doc_data, false);
    }

    fn readArray(self: *const Self, pos: *usize) !BsonArray {
        const array_start = pos.*;
        const array_size = self.readI32(pos);
        const array_data = self.data[array_start .. array_start + @as(usize, @intCast(array_size))];

        pos.* = array_start + @as(usize, @intCast(array_size));

        return BsonArray.init(self.allocator, array_data);
    }

    fn skipValue(self: *const Self, tag: u8, pos: *usize) !void {
        return skipValueInData(self.data, pos, tag);
    }
};

pub const BsonArray = struct {
    allocator: std.mem.Allocator,
    data: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Self {
        return .{
            .allocator = allocator,
            .data = data,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn len(self: *const Self) !usize {
        var pos: usize = 4;
        const array_size = std.mem.readInt(i32, self.data[0..4], .little);
        const array_end = @as(usize, @intCast(array_size));

        var count: usize = 0;
        while (pos < array_end - 1) {
            const tag_byte = self.data[pos];
            if (tag_byte == 0) break;

            pos += 1;
            _ = try self.readCString(&pos);
            try self.skipValue(tag_byte, &pos);
            count += 1;
        }

        return count;
    }

    pub fn get(self: *const Self, index: usize) !?Value {
        var pos: usize = 4;
        const array_size = std.mem.readInt(i32, self.data[0..4], .little);
        const array_end = @as(usize, @intCast(array_size));

        var current_index: usize = 0;
        while (pos < array_end - 1) {
            const tag_byte = self.data[pos];
            if (tag_byte == 0) break;

            pos += 1;
            _ = try self.readCString(&pos);

            if (current_index == index) {
                const doc = BsonDocument{
                    .allocator = self.allocator,
                    .data = self.data,
                    .owned = false,
                };
                return try doc.readValue(tag_byte, &pos);
            } else {
                try self.skipValue(tag_byte, &pos);
            }

            current_index += 1;
        }

        return null;
    }

    fn readCString(self: *const Self, pos: *usize) ![]const u8 {
        const start = pos.*;
        while (pos.* < self.data.len and self.data[pos.*] != 0) {
            pos.* += 1;
        }

        if (pos.* >= self.data.len) return error.UnexpectedEof;

        const str = self.data[start..pos.*];
        pos.* += 1;

        return str;
    }

    fn readI32(self: *const Self, pos: *usize) i32 {
        const value = std.mem.readInt(i32, self.data[pos.*..][0..4], .little);
        pos.* += 4;
        return value;
    }

    fn skipValue(self: *const Self, tag: u8, pos: *usize) !void {
        return skipValueInData(self.data, pos, tag);
    }
};
