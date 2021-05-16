const std = @import("std");
const wav = @import("wav.zig");

const interlace_sample_count = 33280;

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
        std.debug.print("Usage: deinterlace [--drop-extra] FILE.wav\n", .{});
        return @as(u8, 1);
    }
    var args = all_args[1..];
    var drop_extra = false;

    {
        var new_arg_count: usize = 0;
        defer args = args[0..new_arg_count];
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--drop-extra")) {
                drop_extra = true;
            } else {
                args[new_arg_count] = arg;
                new_arg_count += 1;
            }
        }
    }
    return deinterlace(args, .{ .drop_extra = drop_extra });
}

fn deinterlace(args: [][]const u8, opt: struct { drop_extra: bool }) !u8 {
    if (args.len != 1) {
        std.debug.print("Error: expected a wav FILE but got {} args\n", .{args.len});
        return @as(u8, 1);
    }
    const filename = args[0];
    const basename = blk: {
        if (std.mem.endsWith(u8, filename, ".wav"))
            break :blk filename[0 .. filename.len - 4];
        std.log.err("filename did not end with '.wav'", .{});
        return @as(u8, 1);
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

    const combined_sample_count = audio.info.num_samples / 2;
    if (combined_sample_count * 2 != audio.info.num_samples) {
        std.log.err("sample count {} is not divisible by 2!\n", .{audio.info.num_samples});
        return 1;
    }

    // ensure the sample count is divisible by the interlace size
    const chunk_count = combined_sample_count / interlace_sample_count;
    const truncated_sample_count = chunk_count * interlace_sample_count;
    if (truncated_sample_count != combined_sample_count) {
        const prefix: []const u8 = if (opt.drop_extra) "warning" else "error";
        std.debug.print("{s}: quad channel sample count {} is not divisible by the interlace size {}, there are {} extra samples\n", .{ prefix, combined_sample_count, interlace_sample_count, combined_sample_count - truncated_sample_count });
        if (!opt.drop_extra) {
            std.debug.print("use '--drop-extra' to deinterlace anyway\n", .{});
            return 1;
        }
    }
    if (audio.info.format != .signed16_lsb) {
        std.log.err("expected format {} but got {}\n", .{ wav.Format.signed16_lsb, audio.info.format });
        return 1;
    }

    std.log.info("chunk count {}", .{chunk_count});
    return renderFrontBack(basename, audio, combined_sample_count, chunk_count);
}

fn renderFrontBack(basename: []const u8, audio: Audio, combined_sample_count: usize, chunk_count: usize) !u8 {
    const stereo_count = 2;
    const sample_size = 2;
    const fnt_buf = try std.heap.page_allocator.alignedAlloc(u8, 2, combined_sample_count * stereo_count * sample_size);
    const bck_buf = try std.heap.page_allocator.alignedAlloc(u8, 2, combined_sample_count * stereo_count * sample_size);

    {
        const interlaced = @ptrCast([*]u16, audio.buffer.ptr)[0 .. audio.info.num_samples * audio.info.num_channels];
        const fnt = @ptrCast([*]u16, fnt_buf.ptr)[0 .. combined_sample_count * stereo_count];
        const bck = @ptrCast([*]u16, bck_buf.ptr)[0 .. combined_sample_count * stereo_count];
        std.debug.assert(interlaced.len == fnt.len + bck.len);

        var chunk: usize = 0;
        var write_offset: usize = 0;
        var interlaced_offset: usize = 0;

        const interlace_2nd_offset = interlace_sample_count * audio.info.num_channels;

        while (chunk < chunk_count) : (chunk += 1) {
            //std.log.info("writing chunk {}", .{chunk});
            var i: usize = 0;
            while (i < interlace_sample_count) : (i += 1) {
                fnt[write_offset + 0] = interlaced[interlaced_offset + 0];
                fnt[write_offset + 1] = interlaced[interlaced_offset + 1];
                bck[write_offset + 0] = interlaced[interlaced_offset + interlace_2nd_offset + 0];
                bck[write_offset + 1] = interlaced[interlaced_offset + interlace_2nd_offset + 1];
                write_offset += 2;
                interlaced_offset += 2;
            }

            // uncomment this to add spikes at each chunk start, useful
            // for finding the interlace value
            //fnt[write_offset - interlace_sample_count * 2] = 0x7fff;

            interlaced_offset += interlace_sample_count * audio.info.num_channels;
        }

        std.mem.set(u16, fnt[write_offset..], 0);
        std.mem.set(u16, bck[write_offset..], 0);
    }

    const stereo_audio_info = wav.PreloadedInfo{
        .num_channels = stereo_count,
        .sample_rate = audio.info.sample_rate,
        .format = audio.info.format,
        .num_samples = combined_sample_count,
    };

    {
        const out_filename = try std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ basename, "_fnt.wav" });
        defer std.heap.page_allocator.free(out_filename);
        try saveAudio(out_filename, .{ .info = stereo_audio_info, .buffer = fnt_buf });
    }
    {
        const out_filename = try std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ basename, "_bck.wav" });
        defer std.heap.page_allocator.free(out_filename);
        try saveAudio(out_filename, .{ .info = stereo_audio_info, .buffer = bck_buf });
    }

    return 0;
}

fn renderQuad() void {
    const quad_channel_count = 4;
    const sample_size = 2;
    const quad_buf = try std.heap.page_allocator.alignedAlloc(u8, 2, combined_sample_count * quad_channel_count * sample_size);

    {
        const interlaced = @ptrCast([*]u16, audio.buffer.ptr)[0 .. audio.info.num_samples * audio.info.num_channels];
        const quad = @ptrCast([*]u16, quad_buf.ptr)[0 .. combined_sample_count * quad_channel_count];
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
        .num_samples = combined_sample_count,
    };

    {
        const out_filename = try std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ basename, "-quad.wav" });
        defer std.heap.page_allocator.free(out_filename);
        try saveAudio(out_filename, .{ .info = quad_audio_info, .buffer = quad_buf });
    }

    return 0;
}
