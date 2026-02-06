const std = @import("std");

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const fname = args.next() orelse return error.NoFileProvided;

    var buf: [0x1000]u8 = undefined;

    const file = try std.fs.cwd().openFileZ(fname, .{ .mode = .read_only });
    const stat = try file.stat();
    std.debug.print("filesize: {} bytes (this will be ommited in non-tty output)\n", .{stat.size});
    const bytes_read = try file.readAll(&buf);

    outer:
    for (0..0x1000/16) |i| {
        std.debug.print("\x1b[90m{x:0>4}: \x1b[0m", .{ i * 16 });
        var cnt: u3 = 0;
        for (0..16) |j| {
            if (i * 16 + j > bytes_read) {
                std.debug.print("   ", .{});
            } else {
                const byte = buf[16 * i + j];
                if (byte == 0x00) {
                    std.debug.print("\x1b[31m{x:0>2}", .{ buf[16 * i + j] });
                } else if (byte == 0xff) {
                    std.debug.print("\x1b[34m{x:0>2}", .{ buf[16 * i + j] });
                } else if (std.ascii.isControl(byte)) {
                    std.debug.print("\x1b[33m{x:0>2}", .{ buf[16 * i + j] });
                } else if (std.ascii.isAscii(byte)) {
                    std.debug.print("\x1b[36m{x:0>2}", .{ buf[16 * i + j] });
                } else {
                    std.debug.print("\x1b[0m{x:0>2}", .{ buf[16 * i + j] });
                }
                std.debug.print(" ", .{});
            }

            if (cnt == 7 and j < 15) {
                std.debug.print(" ", .{});
            }
            cnt +%= 1;
        }

        std.debug.print(" \x1b[32m", .{});

        for (0..16) |j| {
            if (i * 16 + j > bytes_read) {
                break :outer;
            }

            if (std.ascii.isAscii(buf[16 * i + j]) and !std.ascii.isControl(buf[16*i+j])) {
                std.debug.print("\x1b[36m{c}", .{ buf[16 * i + j] });
            } else {
                std.debug.print("\x1b[31m.", .{});
            }
        }

        std.debug.print("\n", .{});
    }

    std.debug.print("\x1b[0m\n", .{});
}
