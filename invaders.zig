const std = @import("std");
const debug = std.debug;
const print = debug.print;
const native_endian = @import("builtin").target.cpu.arch.endian();
const os = std.os;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;

const Mode = enum {
    test1,
    test2,
    dev,
};

const Config = struct {
    max_steps : u64,
    trace_from : u64,
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
            .max_steps = 50_000,
            .trace_from = 0,
            .trace_every = 1,
            .trace_pixs = false,
        },
        .test2 => Config {
            .max_steps = 9_260_000, //OOB write 9_264_118
            .trace_from = 0,
            .trace_every = 10_000,
            .trace_pixs = true,
        },
        .dev => Config {
            .max_steps = 10_000_000,
            .trace_from = 0,
            .trace_every = 10_000,
            .trace_pixs = true,
        },
    };
}

pub fn main() !void {
    const config = parse_config();
    //print("** Zig Invaders ** {any}\n",.{config});
    var mem = [_]u8{0} ** mem_size;
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

        if (state.cycle >= state.next_wakeup) {
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

const State = struct {
    config : Config,
    step : u64, //number of instructions executed
    cycle : u64, //simulated cycles (at clock speed of 2 MhZ)
    mem : []u8,
    cpu : Cpu,
    shifter: Shifter,
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
        .shifter = init_shiter(),
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
        var res: u8 = 0;
        if (self.flagS == 1) res += 0x80;
        if (self.flagZ == 1) res += 0x40;
        if (self.flagY == 1) res += 0x01;
        return res;
    }
    fn restoreFlags(self:*Cpu, byte: u8) void {
        self.flagS = if (byte & 0x80 == 0) 0 else 1;
        self.flagZ = if (byte & 0x40 == 0) 0 else 1;
        self.flagY = if (byte & 0x01 == 0) 0 else 1;
    }
};

fn init_cpu() Cpu {
    return Cpu {
        .pc = 0, .sp = 0, .a = 0, .hl = 0,
        .b = 0, .c = 0, .d = 0, .e = 0,
        .flagS = 0, .flagZ = 0, .flagY = 0,
    };
}

const Shifter = struct {
    lo : u8,
    hi : u8,
    offset : u3,
};

fn init_shiter() Shifter {
    return Shifter { .lo = 0, .hi = 0, .offset = 0 };
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

fn count_bits(byte: u8) u8 {
    //TODO: comptime inline loop
    var res : u8 = 0;
    res += (if (byte & (1<<0) == 0) 0 else 1);
    res += (if (byte & (1<<1) == 0) 0 else 1);
    res += (if (byte & (1<<2) == 0) 0 else 1);
    res += (if (byte & (1<<3) == 0) 0 else 1);
    res += (if (byte & (1<<4) == 0) 0 else 1);
    res += (if (byte & (1<<5) == 0) 0 else 1);
    res += (if (byte & (1<<6) == 0) 0 else 1);
    res += (if (byte & (1<<7) == 0) 0 else 1);
    return res;
}

fn count_on_pixels(mem: []u8) u64 {
    var res: u64 = 0;
    for (0x2400..0x4000) |i| { //video ram
        res += count_bits(mem[i]);
    }
    return res;
}

fn traceOp(state: *State, comptime fmt: []const u8, args: anytype) void {
    if (state.step >= state.config.trace_from and state.step % state.config.trace_every == 0) {
        printTraceLine(state);
        print(fmt,args);
        if (state.config.trace_pixs) {
            print(" #pixs:{d}\n",.{count_on_pixels(state.mem)});
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
    state.cpu.sp += 1; // increment after read
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

fn increment(byte: u8) u8 {
    return if (byte<0xFF) byte + 1 else 0x00;
}

fn setFlags(cpu: *Cpu, byte: u8) void {
    cpu.flagS = if (byte & 0x80 == 0) 0 else 1;
    cpu.flagZ = if (byte == 0) 1 else 0;
}

fn doOut(state: *State, channel: u8, value : u8) void {
    switch (channel) {
        0x02 => state.shifter.offset = @truncate(value),
        0x03 => {}, //TODO sound
        0x04 => {
            // looks like generated C code in space-invaders repo has these assignments swapped. bug?
            state.shifter.lo = state.shifter.hi;
            state.shifter.hi = value;
        },
        0x05 => {}, //TODO sound
        0x06 => {}, //watchdog; ignore
        else => {
            print("**doOut: channel={X:0>2} value={X:0>2}\n", .{channel,value});
            stop(state,0xD3);
        },
    }
}

fn doIn(state: *State, channel: u8) u8 {
    switch (channel) {
        0x01 => {
            return 0x01; //TODO: input controls and dip switches
        },
        0x02 => {
            return 0x00; //TODO: input controls and dip switches
        },
        0x03 => {
            return
                (state.shifter.hi << state.shifter.offset)
                | ((state.shifter.lo >> (7 - state.shifter.offset)) >> 1);
        },
        else => {
            print("**doIn: channel={X:0>2}\n", .{channel});
            unreachable;
        },
    }
}

fn dad(cpu: *Cpu, word: u16) void { // double add
    const res : u17 = @as(u17,cpu.hl) + @as(u17,word);
    cpu.hl = @truncate(res);
    cpu.flagY = @truncate(res >> 16);
}

fn add_with_carry(cpu: *Cpu, byte: u8, cin: u1) void {
    const res: u9 = @as(u9,cpu.a) + @as(u9,byte) + cin;
    const res_byte: u8 = @truncate(res);
    cpu.a = res_byte;
    setFlags(cpu,res_byte);
    cpu.flagY = @truncate(res >> 8);
}

fn subtract_with_borrow(cpu: *Cpu, a: u8, b0 : u8, borrow: u1) u8 {
    const b = b0 + borrow;
    if (b>a) {
        cpu.flagY = 1;
        const xres = 256 + @as(u9,a) - @as(u9,b);
        const res : u8 = @truncate(xres);
        setFlags(cpu,res);
        return res;
    }
    cpu.flagY = 0;
    const xres = @as(u9,a - b);
    const res : u8 = @truncate(xres);
    setFlags(cpu,res);
    return res;
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
        0x03 => {
            traceOp(state, "INC  BC", .{});
            cpu.setBC(1 + cpu.BC());
            state.cycle += 5;
        },
        0x04 => {
            traceOp(state, "INC  B", .{});
            const byte = increment(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
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
        0x07 => {
            traceOp(state, "RLCA", .{});
            const shunted : u1 = @truncate(cpu.a >> 7);
            cpu.a = cpu.a<<1 | shunted;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x09 => {
            traceOp(state, "ADD  HL,BC", .{});
            dad(cpu,cpu.BC());
            state.cycle += 10;
        },
        0x0A => {
            traceOp(state, "LD   A,(BC)", .{});
            cpu.a = state.mem[cpu.BC()];
            state.cycle += 7;
        },
        0x0C => {
            traceOp(state, "INC  C", .{});
            const byte = increment(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
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
            const shunted : u1 = @truncate(cpu.a);
            cpu.a = @as(u8,shunted)<<7 | cpu.a>>1;
            cpu.flagY = shunted;
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
        0x14 => {
            traceOp(state, "INC  D", .{});
            const byte = increment(cpu.d);
            cpu.d = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x15 => {
            traceOp(state, "DEC  D", .{});
            const byte = decrement(cpu.d);
            cpu.d = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x16 => {
            const byte = fetch(state);
            traceOp(state, "LD   D,{X:0>2}", .{byte});
            cpu.d = byte;
            state.cycle += 7;
        },
        0x19 => {
            traceOp(state, "ADD  HL,DE", .{});
            dad(cpu,cpu.DE());
            state.cycle += 10;
        },
        0x1A => {
            traceOp(state, "LD   A,(DE)", .{});
            cpu.a = state.mem[cpu.DE()];
            state.cycle += 7;
        },
        0x1F => {
            traceOp(state, "RAR", .{});
            const shunted : u1 = @truncate(cpu.a);
            cpu.a = @as(u8,cpu.flagY)<<7 | cpu.a>>1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x21 => {
            const word = fetch16(state);
            traceOp(state, "LD   HL,{X:0>4}", .{word});
            cpu.hl = word;
            state.cycle += 10;
        },
        0x22 => {
            const word = fetch16(state);
            traceOp(state, "LD   ({X:0>4}),HL", .{word});
            state.mem[word] = lo(cpu.hl);
            state.mem[word+1] = hi(cpu.hl);
            state.cycle += 16;
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
            dad(cpu,cpu.hl);
            state.cycle += 10;
        },
        0x2A => {
            const word = fetch16(state);
            traceOp(state, "LD   HL,({X:0>4})", .{word});
            cpu.hl = hilo (state.mem[word+1], state.mem[word]);
            state.cycle += 16;
        },
        0x2B => {
            traceOp(state, "DEC  HL", .{});
            cpu.hl = if (cpu.hl == 0) 0xffff else cpu.hl - 1;
            state.cycle += 5;
        },
        0x2C => {
            traceOp(state, "INC  L", .{});
            const byte = increment(lo(cpu.hl));
            cpu.hl = hilo(hi(cpu.hl),byte);
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x2E => {
            const byte = fetch(state);
            traceOp(state, "LD   L,{X:0>2}", .{byte});
            cpu.hl = hilo(hi(cpu.hl),byte);
            state.cycle += 7;
        },
        0x2F => {
            traceOp(state, "CPL", .{});
            cpu.a = ~ cpu.a;
            state.cycle += 4;
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
        0x34 => {
            traceOp(state, "INC  (HL)", .{});
            const byte = increment(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu,byte);
            state.cycle += 10;
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
        0x37 => {
            traceOp(state, "SCF", .{});
            cpu.flagY = 1;
            state.cycle += 4;
        },
        0x3A => {
            const word = fetch16(state);
            traceOp(state, "LD   A,({X:0>4})", .{word});
            cpu.a = state.mem[word];
            state.cycle += 13;
        },
        0x3C => {
            traceOp(state, "INC  A", .{});
            const byte = increment(cpu.a);
            cpu.a = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x3D => {
            traceOp(state, "DEC  A", .{});
            const byte = decrement(cpu.a);
            cpu.a = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x3E => {
            const byte = fetch(state);
            traceOp(state, "LD   A,{X:0>2}", .{byte});
            cpu.a = byte;
            state.cycle += 7;
        },
        0x41 => {
            traceOp(state, "LD   B,C", .{});
            cpu.b = cpu.c;
            state.cycle += 5;
        },
        0x46 => {
            traceOp(state, "LD   B,(HL)", .{});
            cpu.b = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x47 => {
            traceOp(state, "LD   B,A", .{});
            cpu.b = cpu.a;
            state.cycle += 5;
        },
        0x4E => {
            traceOp(state, "LD   C,(HL)", .{});
            cpu.c = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x4F => {
            traceOp(state, "LD   C,A", .{});
            cpu.c = cpu.a;
            state.cycle += 5;
        },
        0x56 => {
            traceOp(state, "LD   D,(HL)", .{});
            cpu.d = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x57 => {
            traceOp(state, "LD   D,A", .{});
            cpu.d = cpu.a;
            state.cycle += 5;
        },
        0x5E => {
            traceOp(state, "LD   E,(HL)", .{});
            cpu.e = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x5F => {
            traceOp(state, "LD   E,A", .{});
            cpu.e = cpu.a;
            state.cycle += 5;
        },
        0x61 => {
            traceOp(state, "LD   H,C", .{});
            cpu.hl = hilo(cpu.c,lo(cpu.hl));
            state.cycle += 5;
        },
        0x65 => {
            traceOp(state, "LD   H,L", .{});
            cpu.hl = hilo(lo(cpu.hl),lo(cpu.hl));
            state.cycle += 5;
        },
        0x66 => {
            traceOp(state, "LD   H,(HL)", .{});
            cpu.hl = hilo(state.mem[cpu.hl],lo(cpu.hl));
            state.cycle += 7;
        },
        0x67 => {
            traceOp(state, "LD   H,A", .{});
            cpu.hl = hilo(cpu.a,lo(cpu.hl));
            state.cycle += 5;
        },
        0x68 => {
            traceOp(state, "LD   L,B", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.b);
            state.cycle += 5;
        },
        0x69 => {
            traceOp(state, "LD   L,C", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.c);
            state.cycle += 5;
        },
        0x6F => {
            traceOp(state, "LD   L,A", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.a);
            state.cycle += 5;
        },
        0x70 => {
            traceOp(state, "LD   (HL),B", .{});
            state.mem[cpu.hl] = cpu.b;
            state.cycle += 7;
        },
        0x71 => {
            traceOp(state, "LD   (HL),C", .{});
            state.mem[cpu.hl] = cpu.c;
            state.cycle += 7;
        },
        0x77 => {
            traceOp(state, "LD   (HL),A", .{});
            if (cpu.hl >= mem_size) { stop(state,op); unreachable; }
            state.mem[cpu.hl] = cpu.a;
            state.cycle += 7;
        },
        0x78 => {
            traceOp(state, "LD   A,B", .{});
            cpu.a = cpu.b;
            state.cycle += 5;
        },
        0x79 => {
            traceOp(state, "LD   A,C", .{});
            cpu.a = cpu.c;
            state.cycle += 5;
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
        0x7D => {
            traceOp(state, "LD   A,L", .{});
            cpu.a = lo(cpu.hl);
            state.cycle += 5;
        },
        0x7E => {
            traceOp(state, "LD   A,(HL)", .{});
            cpu.a = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x80 => {
            traceOp(state, "ADD  B", .{});
            add_with_carry(cpu, cpu.b, 0);
            state.cycle += 4;
        },
        0x81 => {
            traceOp(state, "ADD  C", .{});
            add_with_carry(cpu, cpu.c, 0);
            state.cycle += 4;
        },
        0x85 => {
            traceOp(state, "ADD  L", .{});
            add_with_carry(cpu, lo(cpu.hl), 0);
            state.cycle += 4;
        },
        0x86 => {
            traceOp(state, "ADD  (HL)", .{});
            add_with_carry(cpu, state.mem[cpu.hl], 0);
            state.cycle += 7;
        },
        0x97 => {
            traceOp(state, "SUB  A", .{});
            cpu.a = subtract_with_borrow(cpu,cpu.a,cpu.a,0);
            state.cycle += 4;
        },
        0xA0 => {
            traceOp(state, "AND  B", .{});
            const res = cpu.a & cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA6 => {
            traceOp(state, "AND  (HL)", .{});
            const res = cpu.a & state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
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
        0xA8 => {
            traceOp(state, "XOR  B", .{});
            const res = cpu.a ^ cpu.b;
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
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB0 => {
            traceOp(state, "OR   B", .{});
            const res = cpu.a | cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB4 => {
            traceOp(state, "OR   H", .{});
            const res = cpu.a | hi(cpu.hl);
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB6 => {
            traceOp(state, "OR   (HL)", .{});
            const res = cpu.a | state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xB8 => {
            traceOp(state, "CP   B", .{});
            _ = subtract_with_borrow(cpu,cpu.a,cpu.b,0);
            state.cycle += 4;
        },
        0xBC => {
            traceOp(state, "CP   H", .{});
            _ = subtract_with_borrow(cpu,cpu.a,hi(cpu.hl),0);
            state.cycle += 4;
        },
        0xBE => {
            traceOp(state, "CP   (HL)", .{});
            _ = subtract_with_borrow(cpu,cpu.a,state.mem[cpu.hl],0);
            state.cycle += 7;
        },
        0xC0 => {
            traceOp(state, "RET  NZ", .{});
            if (cpu.flagZ == 0) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a,b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
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
            if (cpu.flagZ == 0) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xC3 => {
            const word = fetch16(state);
            traceOp(state, "JP   {X:0>4}", .{word});
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC4 => {
            const word = fetch16(state);
            traceOp(state, "CALL NZ,{X:0>4}", .{word});
            if (cpu.flagZ == 0) {
                pushStack(state,hi(cpu.pc)); // hi then lo
                pushStack(state,lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
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
            add_with_carry(cpu, byte, 0);
            state.cycle += 7;
        },
        0xC8 => {
            traceOp(state, "RET  Z", .{});
            if (cpu.flagZ == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a,b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
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
            if (cpu.flagZ == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xCC => {
            const word = fetch16(state);
            traceOp(state, "CALL Z,{X:0>4}", .{word});
            if (cpu.flagZ == 1) {
                pushStack(state,hi(cpu.pc)); // hi then lo
                pushStack(state,lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
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
        0xD0 => {
            traceOp(state, "RET  NC", .{});
            if (cpu.flagY == 0) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a,b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
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
        0xD4 => {
            const word = fetch16(state);
            traceOp(state, "CALL NC,{X:0>4}", .{word});
            if (cpu.flagY == 0) {
                pushStack(state,hi(cpu.pc)); // hi then lo
                pushStack(state,lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xD5 => {
            traceOp(state, "PUSH DE", .{});
            pushStack(state,cpu.d);
            pushStack(state,cpu.e);
            state.cycle += 11;
        },
        0xD6 => {
            const byte = fetch(state);
            traceOp(state, "SUB  {X:0>2}", .{byte});
            cpu.a = subtract_with_borrow(cpu,cpu.a,byte,0);
            state.cycle += 7;
        },
        0xD7 => {
            traceOp(state, "RST  2", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x10;
            state.cycle += 4;
        },
        0xD8 => {
            traceOp(state, "RET  CY", .{});
            if (cpu.flagY == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a,b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xDA => {
            const word = fetch16(state);
            traceOp(state, "JP   CY,{X:0>4}", .{word});
            if (cpu.flagY == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xDB => {
            const byte = fetch(state);
            traceOp(state, "IN   {X:0>2}", .{byte});
            cpu.a = doIn(state,byte);
            state.cycle += 10;
        },
        0xDE => {
            const byte = fetch(state);
            traceOp(state, "SBC  {X:0>2}", .{byte});
            cpu.a = subtract_with_borrow(cpu,cpu.a,byte,cpu.flagY);
            state.cycle += 7;
        },
        0xE1 => {
            traceOp(state, "POP  HL", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.hl = hilo(a,b);
            state.cycle += 10;
        },
        0xE3 => {
            traceOp(state, "EX   (SP),HL", .{});
            const b = state.mem[state.cpu.sp];
            const a = state.mem[state.cpu.sp+1];
            state.mem[state.cpu.sp] = lo(cpu.hl);
            state.mem[state.cpu.sp+1] = hi(cpu.hl);
            cpu.hl = hilo(a,b);
            state.cycle += 18;
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
        0xE9 => {
            traceOp(state, "JP   (HL)", .{});
            cpu.pc = cpu.hl;
            state.cycle += 5;
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
        0xF6 => {
            const byte = fetch(state);
            traceOp(state, "OR   {X:0>2}", .{byte});
            const res = cpu.a | byte;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xFA => {
            const word = fetch16(state);
            traceOp(state, "JP   MI,{X:0>4}", .{word});
            if (cpu.flagS == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xFB => {
            traceOp(state, "EI", .{});
            state.interrupts_enabled = true;
            state.cycle += 4;
        },
        0xFE => {
            const byte = fetch(state);
            traceOp(state, "CP   {X:0>2}", .{byte});
            _ = subtract_with_borrow(cpu,cpu.a,byte,0);
            state.cycle += 7;
        },
        else => {
            stop(state,op);
        }
    }
}

fn stop(state: *State, op: u8) void {
    printTraceLine(state);
    print("**opcode: {X:0>2}\n{d:8}  STOP", .{op,1+state.step});
    std.process.exit(0);
}
