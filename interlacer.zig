const std = @import("std");
const wav = @import("wav.zig");

const Audio = struct {
    info: wav.PreloadedInfo,
    buffer: []align(2) u8,
};
pub fn loadAudio(reader: *std.fs.File.Reader) !Audio {
    const verbose = true;
    const Loader = wav.Loader(@TypeOf(reader.*), verbose);
    std.log.info("loading wav header...", .{});
    const preloaded = try Loader.preload(reader);
    std.log.info("wav info: {}", .{preloaded});
    const buffer = try std.heap.page_allocator.alignedAlloc(u8, 2, preloaded.getNumBytes());
    errdefer std.heap.page_allocator.free(buffer);
    std.log.info("loading wav data...", .{});
    try Loader.load(reader, preloaded, buffer);
    return Audio{
        .info = preloaded,
        .buffer = buffer,
    };
}

pub fn saveAudio(filename: []const u8, audio: Audio) !void {
    // TODO: programs hangs if file is locked on windows
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    var writer = file.writer();

    const Saver = wav.Saver(@TypeOf(writer));
    std.log.info("saving new wav-file '{s}'...", .{filename});
    try Saver.save(writer, audio.buffer, .{
        .num_channels = audio.info.num_channels,
        .sample_rate = audio.info.sample_rate,
        .format = audio.info.format,
    });
}

pub fn main() !u8 {
    const all_args = try std.process.argsAlloc(std.heap.page_allocator);
    if (all_args.len <= 1) {
        std.debug.print("Deinterlace: interlacer d FILE.wav\n", .{});
        std.debug.print("Interlace  : interlacer i FILE.wav\n", .{});
        return @as(u8, 1);
    }

    const cmd = all_args[1];
    const args = all_args[2..];

    if (std.mem.eql(u8, cmd, "i")) {
        std.log.err("interlace not implemented", .{});
        return 1;
    }

    if (std.mem.eql(u8, cmd, "d")) {
        return deinterlace(args);
    }

    std.log.err("unknown command '{s}', expected 'i' or 'd'", .{cmd});
    return @as(u8, 1);
}

fn deinterlace(args: [][]const u8) !u8 {
    if (args.len != 1) {
        std.debug.print("Error: expected a wav FILE but got {} args\n", .{args.len});
        return 1;
    }
    const filename = args[0];
    const basename = blk: {
        if (std.mem.endsWith(u8, filename, ".wav"))
            break :blk filename[0 .. filename.len - 4];
        std.log.err("filename did not end with '.wav'", .{});
        return 1;
    };

    const audio = blk: {
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();
        var reader = file.reader();
        break :blk try loadAudio(&reader);
    };

    // write -roundtrip.wav file for sanity check
    //{
    //    const out_filename = try std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ basename, "-roundtrip.wav" });
    //    defer std.heap.page_allocator.free(out_filename);
    //    try saveAudio(out_filename, audio);
    //}

    const interlace_sample_count = 33280;

    const quad_sample_count = audio.info.num_samples / 2;
    if (quad_sample_count * 2 != audio.info.num_samples) {
        std.log.err("sample count {} is not divisible by 2!\n", .{audio.info.num_samples});
        return 1;
    }

    // ensure the sample count is divisible by the interlace size
    const chunk_count = quad_sample_count / interlace_sample_count;
    if (chunk_count * interlace_sample_count != quad_sample_count) {
        std.log.err("quad channel sample count {} is not divisible by the interlace size {}", .{ quad_sample_count, interlace_sample_count });
        return 1;
    }
    if (audio.info.format != .signed16_lsb) {
        std.log.err("expected format {} but got {}\n", .{ wav.Format.signed16_lsb, audio.info.format });
        return 1;
    }

    std.log.info("chunk count {}", .{chunk_count});

    const quad_channel_count = 4;
    const sample_size = 2;
    const quad_buf = try std.heap.page_allocator.alignedAlloc(u8, 2, quad_sample_count * quad_channel_count * sample_size);

    {
        const interlaced = @ptrCast([*]u16, audio.buffer.ptr)[0 .. audio.info.num_samples * audio.info.num_channels];
        const quad = @ptrCast([*]u16, quad_buf.ptr)[0 .. quad_sample_count * quad_channel_count];
        std.debug.assert(interlaced.len == quad.len);

        var chunk: usize = 0;
        var quad_offset: usize = 0;
        var interlaced_offset: usize = 0;

        const interlace_2nd_offset = interlace_sample_count * audio.info.num_channels;

        while (chunk < chunk_count) : (chunk += 1) {
            //std.log.info("writing chunk {}", .{chunk});
            var i: usize = 0;
            while (i < interlace_sample_count) : (i += 1) {
                quad[quad_offset + 0] = interlaced[interlaced_offset + 0];
                quad[quad_offset + 1] = interlaced[interlaced_offset + 1];
                quad[quad_offset + 2] = interlaced[interlaced_offset + interlace_2nd_offset + 0];
                quad[quad_offset + 3] = interlaced[interlaced_offset + interlace_2nd_offset + 1];
                quad_offset += 4;
                interlaced_offset += 2;
            }
            interlaced_offset += interlace_sample_count * audio.info.num_channels;
        }
    }

    const quad_audio_info = wav.PreloadedInfo{
        .num_channels = quad_channel_count,
        .sample_rate = audio.info.sample_rate,
        .format = audio.info.format,
        .num_samples = quad_sample_count,
    };

    {
        const out_filename = try std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ basename, "-quad.wav" });
        defer std.heap.page_allocator.free(out_filename);
        try saveAudio(out_filename, .{ .info = quad_audio_info, .buffer = quad_buf });
    }

    return 0;
}
