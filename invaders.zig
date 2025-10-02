const std = @import("std");
const print = std.debug.print;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;

pub fn main() !void {
    print("** Zig Invaders **\n",.{});
    var mem : [mem_size]u8 = undefined;
    try load_roms(&mem);
    //dump_mem(&mem);
}

pub fn load_roms(mem : []u8) !void {
    const dir = std.fs.cwd();
    _ = try dir.readFile("../space-invaders/roms/invaders.h", mem[0..]);
    _ = try dir.readFile("../space-invaders/roms/invaders.g", mem[rom_size..]);
    _ = try dir.readFile("../space-invaders/roms/invaders.f", mem[2*rom_size..]);
    _ = try dir.readFile("../space-invaders/roms/invaders.e", mem[3*rom_size..]);
}

pub fn dump_mem(mem : []u8) void {
    const elems_per_row = 16;
    for (0..mem_size / elems_per_row) |row| {
        for (0..elems_per_row) |col| {
            const i = elems_per_row * row + col;
            print(" {x:0>2}", .{mem[i]});
        }
        print("\n",.{});
    }
}
