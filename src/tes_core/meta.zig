const std = @import("std");

/// Given an Enum(e) produce an Enum type
/// that contains a subset of the fields in e
pub fn Subset(comptime e: type, comptime fields: []const e) type {
    const info = @typeInfo(e);

    const enumInfo = switch (info) {
        .@"enum" => |i| i,
        else => @compileError("Subset is not implemented for types other than enum"),
    };

    const fieldNames: [fields.len][]const u8 = undefined;
    const fieldValues: [fields.len]enumInfo.tag_type = undefined;

    for (fields, 0..) |field, idx| {
        fieldNames[idx] = @tagName(field);
        fieldValues[idx] = @intFromEnum(field);
    }

    return @Enum(
        enumInfo.tag_type,
        if (enumInfo.is_exhaustive) .exhaustive else .nonexhaustive,
        &fieldNames,
        &fieldValues,
    );
}
