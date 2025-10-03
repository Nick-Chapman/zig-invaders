const std = @import("std");
const print = std.debug.print;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;
//const stdout = std.io.getStdOut().writer();

const max_steps = 50003;

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
    a : u8,
    b : u8,
    c : u8,
    d : u8,
    e : u8,
    hl : u16,
    flagS : u1,
    flagZ : u1,
    //flagA : u1,
    //flagP : u1,
    flagY : u1,
    fn setDE(self:*Cpu, word : u16) void {
        self.d = hi(word);
        self.e = lo(word);
    }
};

fn run(mem : []u8) void {
    var state : State = State {
        .step = 0,
        .cycle = 0,
        .mem = mem,
        .cpu = Cpu {
            .pc = 0,
            .sp = 0,
            .a = 0,
            .b = 0,
            .c = 0,
            .d = 0,
            .e = 0,
            .hl = 0,
            .flagS = 0,
            .flagZ = 0,
            //.flagA = 0,
            //.flagP = 0,
            .flagY = 0,
        },
    };
    while (state.step < max_steps) { //TODO control during dev
        step(&state);
        state.step += 1;
    }
}

fn trace(state : *State) void {
    const cpu = state.cpu;
    print("{d:8}  [{d:0>8}] PC:{X:0>4} A:{X:0>2} B:{X:0>2} C:{X:0>2} D:{X:0>2} E:{X:0>2} HL:{X:0>4} SP:{X:0>4} SZAPY:{x}{x}??{x} : ", .{
        state.step,
        state.cycle,
        cpu.pc,
        cpu.a,
        cpu.b,
        cpu.c,
        cpu.d,
        cpu.e,
        cpu.hl,
        cpu.sp,
        cpu.flagS,
        cpu.flagZ,
        //cpu.flagA,
        //cpu.flagP,
        cpu.flagY,
    });
}

fn lo(word: u16) u8 {
    return @truncate(word);
}

fn hi(word: u16) u8 {
    return @truncate(word >> 8);
}

fn pushStack(state: *State, byte: u8) void {
    state.cpu.sp -= 1; // decrement before write
    state.mem[state.cpu.sp] = byte;
}

fn popStack(state: *State) u8 {
    // read before increment
    const byte = state.mem[state.cpu.sp];
    state.cpu.sp += 1;
    return byte;
}

fn fetch16(state : *State) u16 {
    const loB = fetch(state);
    const hiB = fetch(state);
    return @as(u16,hiB) << 8 | loB;
}

fn fetch(state : *State) u8 {
    const op = state.mem[state.cpu.pc];
    state.cpu.pc += 1;
    return op;
}

fn decrement(byte: u8) u8 {
    return if (byte>0) byte - 1 else 0xff;
}

fn setFlags(cpu: *Cpu, byte: u8) void {
    cpu.flagS = if (byte & 0x80 == 0) 0 else 1;
    cpu.flagZ = if (byte == 0) 1 else 0;
    //cpu.flagP = parity(byte);
}

// fn parity(byte: u8) u1 { //TODO: compile time compute lookup table!
//     _ = byte;
//     return 1; // TODO: this is a hack. do it right!
// }

fn subtract(cpu: *Cpu, a: u8, b : u8) u9 {
    if (b>a) {
        cpu.flagY = 1;
        return 256 + @as(u9,a) - @as(u9,b);
    }
    cpu.flagY = 0;
    return @as(u9,a - b);
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
        0x5 => {
            trace(state);
            print("DEC  B\n", .{});
            const byte = decrement(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x06 => {
            const byte = fetch(state);
            trace(state);
            print("LD   B,{X:0>2}\n", .{byte});
            cpu.b = byte;
            state.cycle += 7;
        },
        0x11 => {
            const word = fetch16(state);
            trace(state);
            print("LD   DE,{X:0>4}\n", .{word});
            cpu.setDE(word);
            state.cycle += 10;
        },
        0x1A => {
            trace(state);
            print("LD   A,(DE)\n", .{});
            const de = @as(u16,cpu.d) << 8 | cpu.e;
            cpu.a = state.mem[de];
            state.cycle += 7;
        },
        0x21 => {
            const word = fetch16(state);
            trace(state);
            print("LD   HL,{X:0>4}\n", .{word});
            cpu.hl = word;
            state.cycle += 10;
        },
        0x23 => {
            trace(state);
            print("INC  HL\n", .{});
            cpu.hl += 1;
            state.cycle += 5;
        },
        0x13 => {
            trace(state);
            print("INC  DE\n", .{});
            const de = (@as(u16,cpu.d) << 8 | cpu.e);
            cpu.setDE(1+de);
            state.cycle += 5;
        },
        0x31 => {
            const word = fetch16(state);
            trace(state);
            print("LD   SP,{X:0>4}\n", .{word});
            cpu.sp = word;
            state.cycle += 10;
        },
        0x36 => {
            const byte = fetch(state);
            trace(state);
            print("LD   (HL),{X:0>2}\n", .{byte});
            state.mem[cpu.hl] = byte;
            state.cycle += 10;
        },
        0x77 => {
            trace(state);
            print("LD   (HL),A\n", .{});
            state.mem[cpu.hl] = cpu.a;
            state.cycle += 7;
        },
        0x7C => {
            trace(state);
            print("LD   A,H\n", .{});
            cpu.a = hi(cpu.hl);
            state.cycle += 5;
        },
        0xC3 => {
            const word = fetch16(state);
            trace(state);
            print("JP   {X:0>4}\n", .{word});
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC9 => {
            trace(state);
            print("RET\n", .{});
            //cpu.pc = word;
            const loB = popStack(state);
            const hiB = popStack(state);
            const word = @as(u16,hiB) << 8 | loB;
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC2 => {
            const word = fetch16(state);
            trace(state);
            print("JP   NZ,{X:0>4}\n", .{word});
            state.cycle += 10;
            if (cpu.flagZ == 0) { cpu.pc = word; }
        },
        0xCD => {
            const word = fetch16(state);
            trace(state);
            print("CALL {X:0>4}\n", .{word});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = word;
            state.cycle += 17;
        },
        0xFE => {
            const byte = fetch(state);
            trace(state);
            print("CP   {X:0>2}\n", .{byte});
            const xres : u9 = subtract(cpu,cpu.a,byte);
            const res : u8 = @truncate(xres);
            setFlags(cpu,res);
            state.cycle += 7;
        },
        else => {
            trace(state);
            print("**opcode: {X:0>2}\n{d:8}  STOP\n", .{op,1+state.step});
            std.process.exit(0);
        }
    }
}
