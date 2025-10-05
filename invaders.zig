const std = @import("std");
const debug = std.debug;
const print = debug.print;
const native_endian = @import("builtin").target.cpu.arch.endian();
const os = std.os;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;

pub fn main() !void {
    const config = parse_config();
    //print("** Zig Invaders ** {any}\n",.{config});
    var mem : [mem_size]u8 = undefined;
    try load_roms(&mem);
    var state = init_state(config,&mem);
    emulation_main_loop(&state);
}

const half_frame_cycles = 2_000_000 / 120;
const first_interrupt_op = 0xCF;
const second_interrupt_op = 0xD7;
const flip_interrupt_op = first_interrupt_op ^ second_interrupt_op;

fn emulation_main_loop(state : *State) void {
    while (state.step <= state.config.max_steps) {

        if (state.cycle > state.next_wakeup) {
            if (state.interrupts_enabled) {
                step(state,state.next_interrupt_op);
                state.step += 1;
            }
            state.next_wakeup += half_frame_cycles;
            state.next_interrupt_op ^= flip_interrupt_op;
        }
        const op = fetch(state);
        step(state,op);
        state.step += 1;
    }
}

fn load_roms(mem : []u8) !void {
    const dir = std.fs.cwd();
    _ = try dir.readFile("invaders.h", mem[0..]);
    _ = try dir.readFile("invaders.g", mem[rom_size..]);
    _ = try dir.readFile("invaders.f", mem[2*rom_size..]);
    _ = try dir.readFile("invaders.e", mem[3*rom_size..]);
}

const Mode = enum {
    test1,
    test2,
};

const Config = struct {
    max_steps : u64,
    trace_every : u64,
    trace_pixs : bool,
};

fn parse_config() Config {
    const n_args = os.argv.len - 1;
    if (n_args != 1) @panic("need exactly one arg");
    const arg1 = std.mem.span(os.argv[1]);
    const mode = std.meta.stringToEnum(Mode,arg1) orelse @panic("mode");
    return switch (mode) {
        .test1 => Config {
            .max_steps = 50000,
            .trace_every = 1,
            .trace_pixs = false,
        },
        .test2 => Config {
            .max_steps = 30000, //TODO: from 40000 pix is wrong!
            .trace_every = 10000,
            .trace_pixs = true,
        },
    };
}

const State = struct {
    config : Config,
    step : u64, //number of instructions executed
    cycle : u64, //simulated cycles (at clock speed of 2 MhZ)
    mem : []u8,
    cpu : Cpu,
    interrupts_enabled : bool,
    next_wakeup : u64,
    next_interrupt_op : u8,
};

fn init_state(config: Config, mem: []u8) State {
    const state : State = State {
        .config = config,
        .step = 0,
        .cycle = 0,
        .mem = mem,
        .cpu = init_cpu(),
        .interrupts_enabled = false,
        .next_wakeup = half_frame_cycles,
        .next_interrupt_op = first_interrupt_op,
    };
    return state;
}

const Cpu = struct {
    pc : u16,
    sp : u16,
    hl : u16,
    a : u8,
    b : u8,
    c : u8,
    d : u8,
    e : u8,
    flagS : u1,
    flagZ : u1,
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
    fn saveFlags(self:*Cpu) u8 {
        //TODO other flags
        return if (self.flagZ == 1) 0x40 else 0;
    }
    fn restoreFlags(self:*Cpu, byte: u8) void {
        self.flagZ = if (byte & 0x40 == 0) 0 else 1;
        //TODO other flags
    }
};

fn init_cpu() Cpu {
    return Cpu {
        .pc = 0, .sp = 0, .a = 0, .hl = 0,
        .b = 0, .c = 0, .d = 0, .e = 0,
        .flagS = 0, .flagZ = 0, .flagY = 0,
    };
}

fn printTraceLine(state: *State) void {
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
        cpu.flagY,
    });
}

fn traceOp(state: *State, comptime fmt: []const u8, args: anytype) void {
    if (state.step % state.config.trace_every == 0) {
        printTraceLine(state);
        print(fmt,args);
        if (state.config.trace_pixs) {
            print(" #pixs:0\n",.{});
        } else {
            print("\n",.{});
        }
    }
}

fn hilo(a:u8, b:u8) u16 {
    switch (native_endian) {
        .big => return @bitCast([_]u8{a,b}),
        .little => return @bitCast([_]u8{b,a}),
    }
}

fn lo(word: u16) u8 {
    const byte_pair : [2]u8 = @bitCast(word);
    switch (native_endian) {
        .big => return byte_pair[1],
        .little => return byte_pair[0],
    }
}

fn hi(word: u16) u8 {
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
    const byte = state.mem[state.cpu.sp];
    state.cpu.sp += 1; // increment after reead
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
}

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
    switch (channel) {
        0x03 => {}, //TODO sound
        0x05 => {}, //TODO sound
        0x06 => {}, //watchdog; ignore
        else => {
            print("**doOut: channel={X:0>2} value={X:0>2}\n", .{channel,value});
            unreachable;
        },
    }
}

fn doIn(state: *State, channel: u8) u8 {
    _ = state;
    switch (channel) {
        0x01 => {
            return 0x01; //TODO: input controls and dip switches
        },
        0x02 => {
            return 0x00; //TODO: input controls and dip switches
        },
        else => {
            print("**doIn: channel={X:0>2}\n", .{channel});
            unreachable;
        },
    }
}

fn step(state : *State, op:u8) void {
    const cpu = &state.cpu;
    switch (op) {
        0x00 => {
            traceOp(state, "NOP",.{});
            state.cycle += 4;
        },
        0x01 => {
            const word = fetch16(state);
            traceOp(state, "LD   BC,{X:0>4}", .{word});
            cpu.setBC(word);
            state.cycle += 10;
        },
        0x05 => {
            traceOp(state, "DEC  B", .{});
            const byte = decrement(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x06 => {
            const byte = fetch(state);
            traceOp(state, "LD   B,{X:0>2}", .{byte});
            cpu.b = byte;
            state.cycle += 7;
        },
        0x0D => {
            traceOp(state, "DEC  C", .{});
            const byte = decrement(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x0E => {
            const byte = fetch(state);
            traceOp(state, "LD   C,{X:0>2}", .{byte});
            cpu.c = byte;
            state.cycle += 7;
        },
        0x0F => {
            traceOp(state, "RRCA", .{});
            const shunted : bool = cpu.a & 1 == 1;
            cpu.a = if (shunted) cpu.a >> 1 | 0x80 else cpu.a >> 1;
            if (shunted) cpu.flagY = 1;
            state.cycle += 4;
        },
        0x11 => {
            const word = fetch16(state);
            traceOp(state, "LD   DE,{X:0>4}", .{word});
            cpu.setDE(word);
            state.cycle += 10;
        },
        0x13 => {
            traceOp(state, "INC  DE", .{});
            cpu.setDE(1 + cpu.DE());
            state.cycle += 5;
        },
        0x09 => {
            traceOp(state, "ADD  HL,BC", .{});
            cpu.hl = cpu.hl + cpu.BC();
            state.cycle += 10;
        },
        0x19 => {
            traceOp(state, "ADD  HL,DE", .{});
            cpu.hl = cpu.hl + cpu.DE();
            state.cycle += 10;
        },
        0x1A => {
            traceOp(state, "LD   A,(DE)", .{});
            cpu.a = state.mem[cpu.DE()];
            state.cycle += 7;
        },
        0x21 => {
            const word = fetch16(state);
            traceOp(state, "LD   HL,{X:0>4}", .{word});
            cpu.hl = word;
            state.cycle += 10;
        },
        0x23 => {
            traceOp(state, "INC  HL", .{});
            cpu.hl += 1;
            state.cycle += 5;
        },
        0x26 => {
            const byte = fetch(state);
            traceOp(state, "LD   H,{X:0>2}", .{byte});
            cpu.hl = hilo(byte,lo(cpu.hl));
            state.cycle += 7;
        },
        0x29 => {
            traceOp(state, "ADD  HL,HL", .{});
            cpu.hl <<= 1;
            state.cycle += 10;
        },
        0x31 => {
            const word = fetch16(state);
            traceOp(state, "LD   SP,{X:0>4}", .{word});
            cpu.sp = word;
            state.cycle += 10;
        },
        0x32 => {
            const word = fetch16(state);
            traceOp(state, "LD   ({X:0>4}),A", .{word});
            state.mem[word] = cpu.a;
            state.cycle += 13;
        },
        0x35 => {
            traceOp(state, "DEC  (HL)", .{});
            const byte = decrement(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu,byte);
            state.cycle += 10;
        },
        0x36 => {
            const byte = fetch(state);
            traceOp(state, "LD   (HL),{X:0>2}", .{byte});
            state.mem[cpu.hl] = byte;
            state.cycle += 10;
        },
        0x3A => {
            const word = fetch16(state);
            traceOp(state, "LD   A,({X:0>4})", .{word});
            cpu.a = state.mem[word];
            state.cycle += 13;
        },
        0x3E => {
            const byte = fetch(state);
            traceOp(state, "LD   A,{X:0>2}", .{byte});
            cpu.a = byte;
            state.cycle += 7;
        },
        0x56 => {
            traceOp(state, "LD   D,(HL)", .{});
            cpu.d = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x5E => {
            traceOp(state, "LD   E,(HL)", .{});
            cpu.e = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x66 => {
            traceOp(state, "LD   H,(HL)", .{});
            cpu.hl = hilo(state.mem[cpu.hl],lo(cpu.hl));
            state.cycle += 7;
        },
        0x6F => {
            traceOp(state, "LD   L,A", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.a);
            state.cycle += 5;
        },
        0x77 => {
            traceOp(state, "LD   (HL),A", .{});
            state.mem[cpu.hl] = cpu.a;
            state.cycle += 7;
        },
        0x7A => {
            traceOp(state, "LD   A,D", .{});
            cpu.a = cpu.d;
            state.cycle += 5;
        },
        0x7B => {
            traceOp(state, "LD   A,E", .{});
            cpu.a = cpu.e;
            state.cycle += 5;
        },
        0x7C => {
            traceOp(state, "LD   A,H", .{});
            cpu.a = hi(cpu.hl);
            state.cycle += 5;
        },
        0x7E => {
            traceOp(state, "LD   A,(HL)", .{});
            cpu.a = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0xA7 => {
            traceOp(state, "AND  A", .{});
            const res = cpu.a & cpu.a;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAF => {
            traceOp(state, "XOR  A", .{});
            const res = cpu.a ^ cpu.a;
            cpu.a = res;
            setFlags(cpu,res);
            state.cycle += 4;
        },
        0xC1 => {
            traceOp(state, "POP  BC", .{});
            cpu.c = popStack(state);
            cpu.b = popStack(state);
            state.cycle += 10;
        },
        0xC2 => {
            const word = fetch16(state);
            traceOp(state, "JP   NZ,{X:0>4}", .{word});
            state.cycle += 10;
            if (cpu.flagZ == 0) { cpu.pc = word; }
        },
        0xC3 => {
            const word = fetch16(state);
            traceOp(state, "JP   {X:0>4}", .{word});
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC5 => {
            traceOp(state, "PUSH BC", .{});
            pushStack(state,cpu.b);
            pushStack(state,cpu.c);
            state.cycle += 11;
        },
        0xC6 => {
            const byte = fetch(state);
            traceOp(state, "ADD  {X:0>2}", .{byte});
            const res = cpu.a + byte; //TODO carry
            setFlags(cpu,res);
            cpu.a = res;
            state.cycle += 7;
        },
        0xC8 => {
            traceOp(state, "RET  Z", .{});
            if (cpu.flagZ == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a,b);
            }
            state.cycle += 11;
        },
        0xC9 => {
            traceOp(state, "RET", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.pc = hilo(a,b);
            state.cycle += 10;
        },
        0xCA => {
            const word = fetch16(state);
            traceOp(state, "JP   Z,{X:0>4}", .{word});
            if (cpu.flagZ == 1) {
                //TODO: do the conditional jump
                unreachable;
            }
            state.cycle += 10;
        },
        0xCD => {
            const word = fetch16(state);
            traceOp(state, "CALL {X:0>4}", .{word});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = word;
            state.cycle += 17;
        },
        0xCF => {
            traceOp(state, "RST  1", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x08;
            state.cycle += 4;
        },
        0xD1 => {
            traceOp(state, "POP  DE", .{});
            cpu.e = popStack(state);
            cpu.d = popStack(state);
            state.cycle += 10;
        },
        0xD2 => {
            const word = fetch16(state);
            traceOp(state, "JP   NC,{X:0>4}", .{word});
            if (cpu.flagY == 0) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xD3 => {
            const byte = fetch(state);
            traceOp(state, "OUT  {X:0>2}", .{byte});
            doOut(state,byte,cpu.a);
            state.cycle += 10;
        },
        0xD5 => {
            traceOp(state, "PUSH DE", .{});
            pushStack(state,cpu.d);
            pushStack(state,cpu.e);
            state.cycle += 11;
        },
        0xD7 => {
            traceOp(state, "RST  2", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x10;
            state.cycle += 4;
        },
        0xDA => {
            const word = fetch16(state);
            traceOp(state, "JP   CY,{X:0>4}", .{word});
            state.cycle += 10;
            if (cpu.flagY == 1) { cpu.pc = word; }
        },
        0xDB => {
            const byte = fetch(state);
            traceOp(state, "IN   {X:0>2}", .{byte});
            cpu.a = doIn(state,byte);
            state.cycle += 10;
        },
        0xE1 => {
            traceOp(state, "POP  HL", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.hl = hilo(a,b);
            state.cycle += 10;
        },
        0xE5 => {
            traceOp(state, "PUSH HL", .{});
            pushStack(state,hi(cpu.hl));
            pushStack(state,lo(cpu.hl));
            state.cycle += 11;
        },
        0xE6 => {
            const byte = fetch(state);
            traceOp(state, "AND  {X:0>2}", .{byte});
            const res = cpu.a & byte;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xEB => {
            traceOp(state, "EX   DE,HL", .{});
            const de = cpu.DE();
            cpu.setDE(cpu.hl);
            cpu.hl = de;
            state.cycle += 4;
        },
        0xF1 => {
            traceOp(state, "POP  PSW", .{});
            cpu.restoreFlags(popStack(state));
            cpu.a = popStack(state);
            state.cycle += 10;
        },
        0xF5 => {
            traceOp(state, "PUSH PSW", .{});
            pushStack(state,cpu.a);
            pushStack(state,cpu.saveFlags());
            state.cycle += 11;
        },
        0xFB => {
            traceOp(state, "EI", .{});
            state.interrupts_enabled = true;
            state.cycle += 4;
        },
        0xFE => {
            const byte = fetch(state);
            traceOp(state, "CP   {X:0>2}", .{byte});
            const xres : u9 = subtract(cpu,cpu.a,byte);
            const res : u8 = @truncate(xres);
            setFlags(cpu,res);
            state.cycle += 7;
        },
        else => {
            printTraceLine(state);
            print("**opcode: {X:0>2}\n{d:8}  STOP", .{op,1+state.step});
            std.process.exit(0);
        }
    }
}
