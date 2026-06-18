
const std = @import("std");

pub const BsonError = error{
    DocumentTooLarge,
    InvalidType,
    MalformedDocument,
    InvalidUtf8,
    UnexpectedEof,
    InvalidFieldName,
    InvalidArrayIndex,
    InvalidObjectId,
    InvalidBinarySubtype,
    TypeMismatch,
    MissingField,
    OutOfMemory,
    Overflow,
    NoSpaceLeft,
};

pub const Error = BsonError || std.mem.Allocator.Error;
