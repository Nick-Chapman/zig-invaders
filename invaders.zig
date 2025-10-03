const std = @import("std");
const print = std.debug.print;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;
//const stdout = std.io.getStdOut().writer();
const native_endian = @import("builtin").target.cpu.arch.endian();

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
    fn setBC(self:*Cpu, word : u16) void {
        self.b = hi(word);
        self.c = lo(word);
    }
    fn setDE(self:*Cpu, word : u16) void {
        self.d = hi(word);
        self.e = lo(word);
    }
    fn BC(self:*Cpu) u16 {
        return hilo(self.b,self.c);
    }
    fn DE(self:*Cpu) u16 {
        return hilo(self.d,self.e);
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

fn hilo(a:u8, b:u8) u16 {
    //return @as(u16,a) << 8 | b;
    switch (native_endian) {
        .big => return @bitCast([_]u8{a,b}),
        .little => return @bitCast([_]u8{b,a}),
    }
}

fn lo(word: u16) u8 {
    //return @truncate(word);
    const byte_pair : [2]u8 = @bitCast(word);
    switch (native_endian) {
        .big => return byte_pair[1],
        .little => return byte_pair[0],
    }
}

fn hi(word: u16) u8 {
    //return @truncate(word >> 8);
    const byte_pair : [2]u8 = @bitCast(word);
    switch (native_endian) {
        .big => return byte_pair[0],
        .little => return byte_pair[1],
    }
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
    const b = fetch(state);
    const a = fetch(state);
    return hilo(a,b);
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

fn doOut(state: *State, channel: u8, value : u8) void {
    _ = state;
    //print("**doOut: channel={X:0>2} value={X:0>2}\n", .{channel,value});
    _ = channel;
    _ = value;
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
        0x01 => {
            const word = fetch16(state);
            trace(state);
            print("LD   BC,{X:0>4}\n", .{word});
            cpu.setBC(word);
            state.cycle += 10;
        },
        0x05 => {
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
        0x0D => {
            trace(state);
            print("DEC  C\n", .{});
            const byte = decrement(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x0E => {
            const byte = fetch(state);
            trace(state);
            print("LD   C,{X:0>2}\n", .{byte});
            cpu.c = byte;
            state.cycle += 7;
        },
        0x11 => {
            const word = fetch16(state);
            trace(state);
            print("LD   DE,{X:0>4}\n", .{word});
            cpu.setDE(word);
            state.cycle += 10;
        },
        0x13 => {
            trace(state);
            print("INC  DE\n", .{});
            cpu.setDE(1 + cpu.DE());
            state.cycle += 5;
        },
        0x09 => {
            trace(state);
            print("ADD  HL,BC\n", .{});
            cpu.hl = cpu.hl + cpu.BC();
            state.cycle += 10;
        },
        0x19 => {
            trace(state);
            print("ADD  HL,DE\n", .{});
            cpu.hl = cpu.hl + cpu.DE();
            state.cycle += 10;
        },
        0x1A => {
            trace(state);
            print("LD   A,(DE)\n", .{});
            cpu.a = state.mem[cpu.DE()];
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
        0x26 => {
            const byte = fetch(state);
            trace(state);
            print("LD   H,{X:0>2}\n", .{byte});
            cpu.hl = hilo(byte,lo(cpu.hl));
            state.cycle += 7;
        },
        0x29 => {
            trace(state);
            print("ADD  HL,HL\n", .{});
            cpu.hl <<= 1;
            state.cycle += 10;
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
        0x56 => {
            trace(state);
            print("LD   D,(HL)\n", .{});
            cpu.d = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x5E => {
            trace(state);
            print("LD   E,(HL)\n", .{});
            cpu.e = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x66 => {
            trace(state);
            print("LD   H,(HL)\n", .{});
            cpu.hl = hilo(state.mem[cpu.hl],lo(cpu.hl));
            state.cycle += 7;
        },
        0x6F => {
            trace(state);
            print("LD   L,A\n", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.a);
            state.cycle += 5;
        },
        0x77 => {
            trace(state);
            print("LD   (HL),A\n", .{});
            state.mem[cpu.hl] = cpu.a;
            state.cycle += 7;
        },
        0x7A => {
            trace(state);
            print("LD   A,D\n", .{});
            cpu.a = cpu.d;
            state.cycle += 5;
        },
        0x7C => {
            trace(state);
            print("LD   A,H\n", .{});
            cpu.a = hi(cpu.hl);
            state.cycle += 5;
        },
        0x7E => {
            trace(state);
            print("LD   A,(HL)\n", .{});
            cpu.a = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0xC1 => {
            trace(state);
            print("POP  BC\n", .{});
            cpu.c = popStack(state);
            cpu.b = popStack(state);
            state.cycle += 10;
        },
        0xC2 => {
            const word = fetch16(state);
            trace(state);
            print("JP   NZ,{X:0>4}\n", .{word});
            state.cycle += 10;
            if (cpu.flagZ == 0) { cpu.pc = word; }
        },
        0xC3 => {
            const word = fetch16(state);
            trace(state);
            print("JP   {X:0>4}\n", .{word});
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC5 => {
            trace(state);
            print("PUSH BC\n", .{});
            pushStack(state,cpu.b);
            pushStack(state,cpu.c);
            state.cycle += 11;
        },
        0xC9 => {
            trace(state);
            print("RET\n", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.pc = hilo(a,b);
            state.cycle += 10;
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
        0xD1 => {
            trace(state);
            print("POP  DE\n", .{});
            cpu.e = popStack(state);
            cpu.d = popStack(state);
            state.cycle += 10;
        },
        0xD3 => {
            const byte = fetch(state);
            trace(state);
            print("OUT  {X:0>2}\n", .{byte});
            doOut(state,byte,cpu.a);
            state.cycle += 10;
        },
        0xD5 => {
            trace(state);
            print("PUSH DE\n", .{});
            pushStack(state,cpu.d);
            pushStack(state,cpu.e);
            state.cycle += 11;
        },
        0xE1 => {
            trace(state);
            print("POP  HL\n", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.hl = hilo(a,b);
            state.cycle += 10;
        },
        0xE5 => {
            trace(state);
            print("PUSH HL\n", .{});
            pushStack(state,hi(cpu.hl));
            pushStack(state,lo(cpu.hl));
            state.cycle += 11;
        },
        0xEB => {
            trace(state);
            print("EX   DE,HL\n", .{});
            const de = cpu.DE();
            cpu.setDE(cpu.hl);
            cpu.hl = de;
            state.cycle += 4;
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

        //template...
        0xFF => {
            //const byte = fetch(state);
            //const word = fetch16(state);
            trace(state);
            print("TODO-OP-0\n", .{});
            //print("TODO-OP-1 {X:0>2}\n", .{byte});
            //print("TODO-OP-2 {X:0>4}\n", .{word});
            state.cycle += 10;
        },

        else => {
            trace(state);
            print("**opcode: {X:0>2}\n{d:8}  STOP", .{op,1+state.step});
            std.process.exit(0);
        }
    }
}
