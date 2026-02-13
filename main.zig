const std = @import("std");
const assert = std.debug.assert;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const fname = args.next() orelse return error.NoFileProvided;

    const offset_s = args.next() orelse "";
    const offset = if (offset_s.len == 0) 0 else (try std.fmt.parseInt(usize, offset_s, 10));

    const len_s = args.next() orelse "";
    // todo handle if they actually put 0
    const len = if (len_s.len == 0) 0 else (try std.fmt.parseInt(usize, len_s, 10));

    var read_in_buf: [0x1000]u8 = undefined;

    const file = try std.fs.cwd().openFileZ(fname, .{ .mode = .read_only });

    if (offset > 0) {
        _ = try file.seekTo(offset); 
    }

    const fsize = (try file.stat()).size;

    const stdout = std.fs.File.stdout();

    const bytes_per_line = 32;
    var renderer = Renderer.init(fsize, .{ .bytes_per_line=bytes_per_line });

    var file_cursor: usize = offset;
    while (true) {
        const bytes_read = try file.readAll(&read_in_buf);
        if (bytes_read == 0) { break; }

        var block_cursor: usize = 0;
        while (block_cursor < bytes_read) {
            if (len > 0 and file_cursor >= offset + len) { break; }

            var count = @min(bytes_per_line, bytes_read - block_cursor);
            if (len > 0) {
                count = @min(count, offset + len - file_cursor);
            }

            const result = renderer.renderLine(read_in_buf[block_cursor..block_cursor+count], file_cursor);

            block_cursor += count;
            file_cursor += count;

            _ = try stdout.write(result);
        }
    }
}

const Color = enum {
    black, red, green,
    yellow, blue, magenta,
    cyan, white, grey,

    red_bright, green_bright, yellow_bright,
    blue_bright, magenta_bright,
    cyan_bright, white_bright,

    fn asStr(self: Color) []const u8 {
        return switch(self) {
            .black          => "\x1b[30m",
            .red            => "\x1b[31m",
            .green          => "\x1b[32m",
            .yellow         => "\x1b[33m",
            .blue           => "\x1b[34m",
            .magenta        => "\x1b[35m",
            .cyan           => "\x1b[36m",
            .white          => "\x1b[37m",
            .grey           => "\x1b[90m",
            .red_bright     => "\x1b[91m",
            .green_bright   => "\x1b[92m",
            .yellow_bright  => "\x1b[93m",
            .blue_bright    => "\x1b[94m",
            .magenta_bright => "\x1b[95m",
            .cyan_bright    => "\x1b[96m",
            .white_bright   => "\x1b[97m",
        };
    }
};

const Style = enum {
    reset, bold, dim, italic, underline,
    blinking, inverse, hidden, strikethrough,

    fn asStr(self: Style) []const u8 {
        return switch(self) {
            .reset          => "\x1b[0m",
            .bold           => "\x1b[1m",
            .dim            => "\x1b[2m",
            .italic         => "\x1b[3m",
            .underline      => "\x1b[4m",
            .blinking       => "\x1b[5m",
            .inverse        => "\x1b[7m",
            .hidden         => "\x1b[8m",
            .strikethrough  => "\x1b[9m",
        };
    }
};

const Renderer = struct {
    nil_line_count: usize,
    offset_digits: usize,
    buffer: [0x2000]u8,
    cfg: Config,

    cursor: usize = 0,

    style: Style = Style.reset,
    color: Color = Color.white,

    const Config = struct {
        bytes_per_line: usize = 16,
        /// size of contiguous byte groups
        /// Examples
        /// 1 -> `7f ba 88 44 12 ab 5b 0e a9 fb 3d 4a 99 88 4b 00`
        /// 4 -> `7fba8844 12ab5b0e a9fb3d4a 99884b00`
        group_size: usize = 2, 
        /// Will insert an extra divider space between every N bytes
        /// If 0 it will do nothing.
        /// Example with group_size = 1,
        /// 4 -> `7f ba 88 44  12 ab 5b 0e  a9 fb 3d 4a  99 88 4b 00`
        /// 8 -> `7f ba 88 44 12 ab 5b 0e  a9 fb 3d 4a 99 88 4b 00`
        /// If supergroup_size <= group_size it will be silly
        supergroup_size: usize = 4,
        /// Color output using tty escape sequence. Disable if not a tty.
        should_style: bool = true,
        /// Uppercase hex as opposed to lowercase.
        uppercase: bool = false,

        /// First entire line of zeroes will be abbreviated as *, then subsequent
        /// zero lines following that one will return empty buffer. Gets reset
        /// when we encounter a non-zero line of course.
        skip_zeroes: bool = true,
        /// Show offset from start on the left
        offset_prelude: bool = true,

        /// Show ascii representation on the right
        ascii_postlude: bool = true, 
        /// Various integer interpretation postludes
        u16_postlude: bool = false, 
        u32_postlude: bool = false, 
        u64_postlude: bool = false, 

        hr_interval: usize = 0x1000,
    };


    /// The caller is responsible for ensuring line_buffer is sufficiently large.
    /// The Renderer will simply stop inserting bytes if it runs out of space - lines
    /// will effectively be truncated.
    fn init(fsize: usize, config: Config) Renderer {
        const offset_digits = @max(1, (@bitSizeOf(usize) - @clz(fsize) + 3) / 4);

        assert(config.bytes_per_line <= 256);

        return Renderer {
            .nil_line_count = 0,
            .offset_digits = offset_digits,
            .buffer = undefined,
            .cfg = config,
        };
    }

    // rename this
    const Ansi = struct {
        color: Color,
        style: ?Style = null,
    };


    fn writeSliceInner(self: *Renderer, bytes: []const u8) void {
        assert(bytes.len <= self.buffer.len - self.cursor);
        @memcpy(self.buffer[self.cursor..self.cursor+bytes.len], bytes);
        self.cursor += bytes.len;
    }

    fn applyStyle(self: *Renderer, ansi: Ansi) void {
        if (!self.cfg.should_style) { return; }

        if (ansi.style) |style_| {
            if (style_ != self.style) {
                // TODO: atm we are doing more work than we need to in non-reset cases
                self.writeSliceInner(Style.reset.asStr());
                self.writeSliceInner(style_.asStr());
                self.style = style_;
                self.color = Color.white;
            }
        } else if (self.style != Style.reset) {
            self.writeSliceInner(Style.reset.asStr());
            self.style = Style.reset;
            self.color = Color.white;
        } 

        if (self.color != ansi.color) {
            self.writeSliceInner(ansi.color.asStr());
            self.color = ansi.color;
        }
    }

    fn writeSlice(self: *Renderer, bytes: []const u8, ansi: Ansi) void {
        self.applyStyle(ansi);
        self.writeSliceInner(bytes);
    }

    fn writeSliceFmt(self: *Renderer, comptime fmt: []const u8, args: anytype, ansi: Ansi) void {
        self.applyStyle(ansi);
        self.cursor += (std.fmt.bufPrint(self.buffer[self.cursor..], fmt, args) catch unreachable).len;
    }

    fn byteColor(byte: u8) Color {
        if (byte == 0x00) return Color.grey;
        if (byte == 0xff) return Color.blue;
        if (std.ascii.isControl(byte)) return Color.yellow;
        if (std.ascii.isAscii(byte)) return Color.white_bright;
        return Color.magenta;
    }

    fn renderLine(
        self: *Renderer,
        bytes: []const u8,
        start: usize,
    ) []u8 {
        self.cursor = 0;

        const nil_line = self.cfg.skip_zeroes and std.mem.allEqual(u8, bytes, 0);
        if (nil_line) {
            self.nil_line_count += 1;
            if (self.nil_line_count > 1) {
                return self.buffer[0..0];
            }
        } else {
            self.nil_line_count = 0;
        }

        // hr line 
        if (self.cfg.hr_interval > 0 and start > 0 and start % self.cfg.hr_interval == 0) {
            self.writeSlice("───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n", .{.color=Color.white });
        }

        // offset prefix
        if (self.cfg.offset_prelude) {
            self.writeSliceFmt("{x:0>[1]}", .{ start, self.offset_digits }, .{ .color=Color.cyan, .style=Style.italic});
            self.writeSlice(": ", .{ .color=Color.white, .style=Style.reset });
        }

        // if first nil line then print star and return
        if (nil_line) {
            self.writeSlice("..\n", .{ .color=byteColor(0x00) });
            return self.buffer[0..self.cursor];
        } 

        for (0..self.cfg.bytes_per_line) |i| {
            if (i < bytes.len) {
                self.writeSliceFmt("{x:0>2}", .{ bytes[i] }, .{ .color=byteColor(bytes[i]) });
            } else {
                self.writeSlice("  ", .{ .color=Color.white });
            }

            if (self.cfg.group_size > 0) {
                if ((i + 1) % self.cfg.group_size == 0 and i + 1 < self.cfg.bytes_per_line) {
                    self.writeSlice(" ", .{ .color=Color.white });
                }
            }

            if (self.cfg.supergroup_size > 0) {
                if ((i + 1) % self.cfg.supergroup_size == 0 and i + 1 < self.cfg.bytes_per_line) {
                    self.writeSlice(" ", .{ .color=Color.white });
                }
            }
        }

        // ascii-representation postlude
        if (self.cfg.ascii_postlude) {
            self.writeSlice("  ", .{ .color=Color.white });

            for (bytes) |byte| {
                if (std.ascii.isAscii(byte) and !std.ascii.isControl(byte)) {
                    self.writeSliceFmt("{c}", .{ byte }, .{ .color=byteColor(byte), .style=Style.italic });
                } else {
                    self.writeSlice(".", .{ .color=byteColor(byte), .style=Style.italic });
                }
            }
        }

        // integer representation postlude
        if (self.cfg.u16_postlude) {
            self.writeSlice("  ", .{ .color=Color.white });

            for (0..bytes.len/@sizeOf(u16)) |i| {
                const value = std.mem.readInt(u16, bytes[i*@sizeOf(u16)..][0..@sizeOf(u16)], .big);
                self.writeSliceFmt("{d: >5} ", .{ value }, .{ .color=Color.white, .style=Style.italic });
            }
        }

        if (self.cfg.u32_postlude) {
            self.writeSlice("  ", .{ .color=Color.white });

            for (0..bytes.len/@sizeOf(u32)) |i| {
                const value = std.mem.readInt(u32, bytes[i*@sizeOf(u32)..][0..@sizeOf(u32)], .big);
                self.writeSliceFmt("{d: >10} ", .{ value }, .{ .color=Color.white, .style=Style.italic });
            }
        }

        if (self.cfg.u64_postlude) {
            self.writeSlice("  ", .{ .color=Color.white });

            for (0..bytes.len/@sizeOf(u64)) |i| {
                const value = std.mem.readInt(u64, bytes[i*@sizeOf(u64)..][0..@sizeOf(u64)], .big);
                self.writeSliceFmt("{d: >20} ", .{ value }, .{ .color=Color.white, .style=Style.italic });
            }
        }

        self.writeSlice("\n", .{ .color=Color.white, .style=Style.reset });
        return self.buffer[0..self.cursor];
    }
};

