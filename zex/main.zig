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
    black, red, green, yellow, 
    blue, magenta, cyan, white,
    grey,

    cyan_bright, white_bright,

    reset, bold, dim, italic, underline,
    blinking, inverse, hidden, strikethrough,

    fn asStr(self: Color) []const u8 {
        return switch(self) {
            .black   => "\x1b[30m",
            .red     => "\x1b[31m",
            .green   => "\x1b[32m",
            .yellow  => "\x1b[33m",
            .blue    => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan    => "\x1b[36m",
            .white   => "\x1b[37m",
            .grey    => "\x1b[90m",

            .cyan_bright    => "\x1b[96m",
            .white_bright   => "\x1b[97m",

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
    config: Config,

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
        supergroup_size: usize = 0,
        /// First entire line of zeroes will be abbreviated as *, then subsequent
        /// zero lines following that one will return empty buffer. Gets reset
        /// when we encounter a non-zero line of course.
        skip_zeroes: bool = false,
        /// Color output using tty escape sequence. Disable if not a tty.
        should_style: bool = true,
        /// Uppercase hex as opposed to lowercase.
        uppercase: bool = false,
        ascii_postlude: bool = true, 
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
            .config = config,
        };
    }

    fn byteColor(byte: u8) Color {
        if (byte == 0x00) return Color.magenta;
        if (byte == 0xff) return Color.blue;
        if (std.ascii.isControl(byte)) return Color.yellow;
        if (std.ascii.isAscii(byte)) return Color.white_bright;
        return Color.white;
    }

    fn renderLine(
        self: *Renderer,
        bytes: []const u8,
        start: usize,
    ) []u8 {
        var buffer_ptr: usize = 0;
        var prev_color = Color.white;
        const reset = Color.reset.asStr();

        const nil_line = std.mem.allEqual(u8, bytes, 0);
        if (nil_line) {
            self.nil_line_count += 1;
            if (self.nil_line_count > 1) {
                return self.buffer[0..0];
            }
        } else {
            self.nil_line_count = 0;
        }

        if (self.config.should_style) {
            const grey = Color.grey.asStr();
            @memcpy(self.buffer[buffer_ptr..buffer_ptr+grey.len], grey);
            buffer_ptr += grey.len;
        }

        // offset prefix
        buffer_ptr += (
            std.fmt.bufPrint(
                self.buffer[buffer_ptr..], "{x:0>[1]}: ",
                .{start, self.offset_digits})
            catch unreachable
        ).len;

        // if first nil line then print star and return
        if (nil_line) {
            const magenta = Color.magenta.asStr();
            @memcpy(self.buffer[buffer_ptr..buffer_ptr+magenta.len], magenta);
            buffer_ptr += magenta.len;
            const str = "..\n";
            @memcpy(self.buffer[buffer_ptr..buffer_ptr+str.len], str);
            buffer_ptr += str.len;
            return self.buffer[0..buffer_ptr];
        } 

        // actual bytes
        if (self.config.should_style) {
            const white = Color.white.asStr();
            @memcpy(self.buffer[buffer_ptr..buffer_ptr+white.len], white);
            buffer_ptr += white.len;
        }

        for (0..self.config.bytes_per_line) | i| {
            if (i < bytes.len) {
                const byte = bytes[i];

                if (self.config.should_style) {
                    const color = byteColor(byte);

                    if (color != prev_color) {
                        prev_color = color;
                        const ansi = color.asStr();

                        @memcpy(self.buffer[buffer_ptr..buffer_ptr+reset.len], reset);
                        buffer_ptr += reset.len;
                        @memcpy(self.buffer[buffer_ptr..buffer_ptr+ansi.len], ansi);
                        buffer_ptr += ansi.len;
                    }
                }

                buffer_ptr += (
                    std.fmt.bufPrint(self.buffer[buffer_ptr..], "{x:0>2}", .{byte}) 
                    catch unreachable
                ).len;
            } else {
                buffer_ptr += (
                    std.fmt.bufPrint(self.buffer[buffer_ptr..], "  ", .{}) 
                    catch unreachable
                ).len;
            }

            if (self.config.group_size > 0) {
                if ((i + 1) % self.config.group_size == 0 and i + 1 < self.config.bytes_per_line) {
                    self.buffer[buffer_ptr] = ' ';
                    buffer_ptr += 1;
                }
            }

            if (self.config.supergroup_size > 0) {
                if ((i + 1) % self.config.supergroup_size == 0 and i + 1 < self.config.bytes_per_line) {
                    self.buffer[buffer_ptr] = ' ';
                    buffer_ptr += 1;
                }
            }
        }

        // ascii-representation postlude
        if (self.config.ascii_postlude) {
            self.buffer[buffer_ptr] = ' ';
            self.buffer[buffer_ptr + 1] = ' ';
            buffer_ptr += 2;

            if (self.config.should_style) {
                const italic = Color.italic.asStr();
                @memcpy(self.buffer[buffer_ptr..buffer_ptr+italic.len], italic);
                buffer_ptr += italic.len;
                const dim = Color.dim.asStr();
                @memcpy(self.buffer[buffer_ptr..buffer_ptr+dim.len], dim);
                buffer_ptr += dim.len;
            }

            for (bytes) |byte| {
                if (self.config.should_style) {
                    const color = byteColor(byte);

                    if (color != prev_color) {
                        prev_color = color;
                        const ansi = color.asStr();

                        @memcpy(self.buffer[buffer_ptr..buffer_ptr+ansi.len], ansi);
                        buffer_ptr += ansi.len;
                    }
                }

                if (std.ascii.isAscii(byte) and !std.ascii.isControl(byte)) {
                    self.buffer[buffer_ptr] = byte;
                } else {
                    self.buffer[buffer_ptr] = '.';
                }
                buffer_ptr += 1;
            }
        }
        
        if (self.config.should_style) {
            @memcpy(self.buffer[buffer_ptr..buffer_ptr+reset.len], reset);
            buffer_ptr += reset.len;
        }

        self.buffer[buffer_ptr] = '\n';
        buffer_ptr += 1;

        return self.buffer[0..buffer_ptr];
    }
};

