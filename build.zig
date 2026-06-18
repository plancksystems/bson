const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("bson", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    const docs_root = generateDocsRoot(b, "src");
    const docs_mod = b.createModule(.{
        .root_source_file = docs_root,
        .target = target,
        .optimize = optimize,
    });

    const docs_obj = b.addObject(.{
        .name = "bson-docs",
        .root_module = docs_mod,
    });

    const docs_step = b.step("docs", "Build HTML documentation covering every src/.zig file");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs_install.step);
}


fn generateDocsRoot(b: *std.Build, src_dir: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(b.allocator,
        \\//! AUTO-GENERATED docs root. Imports every `.zig` file under `src/`
        \\//! so they all appear in `zig build docs` output. Re-runs each build.
        \\
        \\
    ) catch @panic("OOM");

    const src_abs = b.path(src_dir).getPath3(b, null).toString(b.allocator) catch @panic("OOM");
    walkAndStageDocs(b, wf, &buf, src_abs, src_dir) catch |e| {
        std.debug.panic("docs walk failed for {s}: {}", .{ src_dir, e });
    };

    return wf.add("docs_root.zig", buf.items);
}

fn walkAndStageDocs(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    buf: *std.ArrayList(u8),
    abs: []const u8,
    rel: []const u8,
) !void {
    const io = b.graph.io;
    var dir = try std.Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const child_abs = b.fmt("{s}/{s}", .{ abs, entry.name });
        const child_rel = b.fmt("{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => try walkAndStageDocs(b, wf, buf, child_abs, child_rel),
            .file => {
                _ = wf.addCopyFile(b.path(child_rel), child_rel);
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const ident = docsIdent(b, child_rel);
                const line = b.fmt("pub const {s} = @import(\"{s}\");\n", .{ ident, child_rel });
                buf.appendSlice(b.allocator, line) catch @panic("OOM");
            },
            else => {},
        }
    }
}

fn docsIdent(b: *std.Build, rel_path: []const u8) []const u8 {
    const out = b.allocator.alloc(u8, rel_path.len) catch @panic("OOM");
    for (rel_path, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => c,
            else => '_',
        };
    }
    return out;
}
