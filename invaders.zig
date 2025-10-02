const std = @import("std");
const print = std.debug.print;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;
//const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    //print("** Zig Invaders **\n",.{});
    var mem : [mem_size]u8 = undefined;
    try load_roms(&mem);
    //dump_mem(&mem);
    run(&mem);
}

fn load_roms(mem : []u8) !void {
    const dir = std.fs.cwd();
    _ = try dir.readFile("invaders.h", mem[0..]);
    _ = try dir.readFile("invaders.g", mem[rom_size..]);
    _ = try dir.readFile("invaders.f", mem[2*rom_size..]);
    _ = try dir.readFile("invaders.e", mem[3*rom_size..]);
}

fn dump_mem(mem : []u8) void {
    const elems_per_row = 16;
    for (0..mem_size / elems_per_row) |row| {
        for (0..elems_per_row) |col| {
            const i = elems_per_row * row + col;
            print(" {x:0>2}", .{mem[i]});
        }
        print("\n",.{});
    }
}

const State = struct {
    step : u64,
    cycle : u64,
    mem : []u8,
    cpu : Cpu
};

const Cpu = struct {
    pc : u16,
    sp : u16,
    a : u8
};

fn run(mem : []u8) void {
    var state : State = State {
        .step = 0,
        .cycle = 0,
        .mem = mem,
        .cpu = Cpu {
            .pc = 0,
            .sp = 0,
            .a = 0
        },
    };
    while (true) {
        step(&state);
        state.step += 1;
    }
}

fn trace(state : *State) void {
    const cpu = state.cpu;
    print("{d:8}  [{d:0>8}] PC:{X:0>4} {s} SP:{X:0>4} {s} : ", .{
        state.step,
        state.cycle,
        cpu.pc,
        "A:00 B:00 C:00 D:00 E:00 HL:0000", //TODO
        cpu.sp,
        "SZAPY:00000", //TODO
    });
}

fn step(state : *State) void {
    const op : u8 = fetch(state);
    const cpu = &state.cpu;
    switch (op) {
        0x00 => {
            trace(state);
            print("NOP\n",.{});
            state.cycle += 4;
        },
        0x06 => {
            const byte = fetch(state);
            trace(state);
            print("LD   B,{X:0>2}\n", .{byte});
            //cpu.b = byte; //TODO
            state.cycle += 7;
        },
        0x31 => {
            const lo = fetch(state);
            const hi = fetch(state);
            trace(state);
            print("LD   SP,{X:0>2}{X:0>2}\n", .{hi,lo});
            cpu.sp = @as(u16,hi) << 8 | lo;
            state.cycle += 10;
        },
        0xC3 => {
            const lo = fetch(state);
            const hi = fetch(state);
            trace(state);
            print("JP   {X:0>2}{X:0>2}\n", .{hi,lo});
            cpu.pc = @as(u16,hi) << 8 | lo;
            state.cycle += 10;
        },
        else => {
            trace(state);
            print("**opcode: {X:0>2}\n", .{op});
            std.process.exit(0);
        }
    }
}

fn fetch(state : *State) u8 {
    const op = state.mem[state.cpu.pc];
    state.cpu.pc += 1;
    return op;
}
