const std = @import("std");

const page_size: u64 = 4096;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 3) {
        try printError("Too many arguments", args[0]);
        return error.BadArgCount;
    } else if (args.len < 2) {
        try printError("You must supply a program", args[0]);
        return error.BadArgCount;
    }

    var word_size: u4 = 2;
    if (args.len == 3) {
        word_size = std.fmt.parseInt(u4, args[2], 0) catch |err| {
            switch (err) {
                std.fmt.ParseIntError.Overflow => {
                    try printError("Word size may not be greater than 8", null);
                    return error.InvalidWordSize;
                },
                else => return err,
            }
        };
    }

    if (word_size == 0) {
        try printError("Word size may not equal 0", null);
        return error.InvalidWordSize;
    } else if (word_size > 8) {
        try printError("Word size may not be greater than 8", null);
        return error.InvalidWordSize;
    }

    var memory = std.AutoHashMap(usize, [page_size]u8).init(allocator);
    defer memory.deinit();

    var program = try std.fs.cwd().openFile(args[1], .{});
    defer program.close();

    const program_size = (try program.metadata()).size();

    // Check if program is small enough to fit given the word size while leaving room for mmio
    if (!switch (word_size) {
        inline 1...8 => |bytes| blk: {
            break :blk programInBounds(
                program_size,
                @Type( // UWord
                    .{ .Int = .{
                        .signedness = .unsigned,
                        .bits = @as(u16, bytes) * 8,
                    } },
                ),
            );
        },
        else => unreachable,
    }) {
        try printError("Program too large", null);
        return error.ProgramTooLarge;
    }

    const program_reader = program.reader();

    var i: u64 = 0; // largest option for UWord
    while (i < program_size) : (i +|= page_size) {
        var page: [page_size]u8 = undefined;
        _ = try program_reader.readAll(&page);
        try memory.put(try std.math.divExact(u64, i, 4096), page);
    }

    switch (word_size) {
        inline 1...8 => |bytes| {
            try subleq(
                memory,
                @Type( // UWord
                    .{ .Int = .{
                        .signedness = .unsigned,
                        .bits = @as(u16, bytes) * 8,
                    } },
                ),
                @Type( // IWord
                    .{ .Int = .{
                        .signedness = .signed,
                        .bits = @as(u16, bytes) * 8,
                    } },
                ),
                word_size,
            );
        },
        else => unreachable,
    }
}

fn programInBounds(program_size: u64, comptime UWord: type) bool {
    return program_size <= std.math.maxInt(UWord) - @sizeOf(UWord) * 3;
}

fn subleq(memory: anytype, comptime UWord: type, comptime IWord: type, word_size: UWord) !void {
    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();

    var pc: UWord = 0;
    while (true) {
        const a = try readMemory(&memory, UWord, pc, word_size);
        const b = try readMemory(&memory, UWord, pc + word_size, word_size);
        const c = try readMemory(&memory, UWord, pc + word_size * 2, word_size);

        var processed_a: UWord = undefined;
        if (a == std.math.maxInt(UWord)) {
            processed_a = try getInput(stdin, UWord);
        } else {
            processed_a = try readMemory(&memory, UWord, a, word_size);
        }

        var processed_b: UWord = undefined;
        if (b == std.math.maxInt(UWord)) {
            try stdout.writer().writeByte(@truncate(u8, processed_a));
            processed_b = processed_a;
        } else {
            processed_b = try readMemory(&memory, UWord, b, word_size) -% processed_a;
            try writeMemory(&memory, UWord, b, word_size, processed_b);
        }

        if (@bitCast(IWord, processed_b) <= 0) {
            pc = c;
        } else {
            pc += word_size * 3;
        }

        // is there enough room for next instruction
        if (pc +| 3 >= std.math.maxInt(UWord) - word_size * 3) {
            return; // halt
        }
    }
}

fn readMemory(memory: anytype, comptime UWord: type, address: UWord, word_size: UWord) !UWord {
    const page_index = address / page_size; // floored division
    const page_offset = address % page_size;

    var page = try @constCast(memory).getOrPut(page_index);
    return std.mem.readIntSliceBig(UWord, page.value_ptr[page_offset .. page_offset + word_size]);
}

fn writeMemory(memory: anytype, comptime UWord: type, address: UWord, word_size: UWord, data: UWord) !void {
    const page_index = address / page_size; // floored division
    const page_offset = address % page_size;

    var page = try @constCast(memory).getOrPut(page_index);
    std.mem.writeIntSliceBig(UWord, page.value_ptr[page_offset .. page_offset + word_size], data);
}

/// TODO: Deal with async once it is back
fn getInput(stdin: std.fs.File, comptime UWord: type) !UWord {
    // if (try poller.poll()) {
    //     const byte = stdin.reader().readByte() catch unreachable;
    //     return byte;
    // } else {
    //     return std.math.maxInt(Word);
    // }

    return stdin.reader().readByte() catch
        std.math.maxInt(UWord); // EOF
}

fn printError(message: []const u8, arg0: ?[]u8) !void {
    const stderr = std.io.getStdErr().writer();
    var usage_buffer = [_]u8{0} ** 0x400;

    try stderr.print(
        \\Error: {s}
        \\{s}
    , .{
        message,

        if (arg0 != null)
            std.fmt.bufPrint(
                &usage_buffer,
                \\Usage:
                \\{s} <program> [word size]
                \\Word size defaults to 2
                \\
                \\
            ,
                .{if (arg0.?.len < (usage_buffer.len - 0x80))
                    arg0.?
                else
                    "subleq"},
            ) catch unreachable
        else
            "\n",
    });
}
