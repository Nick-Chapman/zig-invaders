const std = @import("std");
const debug = std.debug;
const print = debug.print;
const native_endian = @import("builtin").target.cpu.arch.endian();
const os = std.os;
const rom_size = 2 * 1024;
const mem_size = 16 * 1024;

const two_million = 2_000_000;
const clock_frequency = two_million; // of the 8080 CPU being simulated

const billion = 1_000_000_000;
const nanos_per_clock_cycle = billion / clock_frequency; //500

fn mono_clock_ns() u64 { // do time computation in nano-seconds.
    const linux = std.os.linux;
    const clock_id = linux.clockid_t.MONOTONIC;
    const ts : linux.timespec = std.posix.clock_gettime(clock_id) catch unreachable;
    const n : i64 = ts.sec * billion + ts.nsec;
    return @intCast(n);
}

const Mode = enum {
    test1,
    test2,
    dev,
    speed,
    graphics,
};

fn parse_mode() Mode {
    const n_args = os.argv.len - 1;
    if (n_args == 0) return .graphics;
    if (n_args > 1) @panic("need at most one arg");
    const arg1 = std.mem.span(os.argv[1]);
    return std.meta.stringToEnum(Mode,arg1) orelse @panic("mode");
}

const Config = struct {
    max_steps : u64,
    trace_from : u64,
    trace_every : u64,
    trace_pixs : bool,
};

fn configure(mode: Mode) Config {
    return switch (mode) {
        .test1 => Config {
            .max_steps = 50_000,
            .trace_from = 0,
            .trace_every = 1,
            .trace_pixs = false,
        },
        .test2 => Config {
            .max_steps = 10_000_000,
            .trace_from = 0,
            .trace_every = 10_000,
            .trace_pixs = true,
        },
        .dev => Config {
            .max_steps = 10_000_000,
            .trace_from = 0,
            .trace_every = 1_000_000,
            .trace_pixs = true,
        },
        .speed => Config {
            .max_steps = 2_000_000, // was 200mil for ReleaseFast
            .trace_from = 1,
            .trace_every = 1_000_000,
            .trace_pixs = false
        },
        .graphics => Config {
            .max_steps = 0,
            .trace_from = 0,
            .trace_every = 100_000,
            .trace_pixs = false
        },
    };
}

pub fn main() !void {
    const mode = parse_mode();
    const config = configure(mode);
    //print("** Zig Invaders ** {any}\n",.{config});
    var mem = [_]u8{0} ** mem_size;
    try load_roms(&mem);
    var state = init_state(config,&mem);

    if (mode == .graphics) {
        try graphics_main(&state);
        return;
    }

    const tic = mono_clock_ns();

    const enable_trace = ! (mode == .speed);

    switch (enable_trace) {
        inline else => |enable_trace_ct| {
            emulation_main_loop(enable_trace_ct, &state);
        }
    }

    const toc = mono_clock_ns();

    if (mode == .speed) {
        const cycles = state.cycle;
        const wall_ns : u64 = toc - tic;
        const sim_s = @as(f32,@floatFromInt(cycles)) / clock_frequency;
        const wall_s = @as(f32,@floatFromInt(wall_ns)) / billion;
        const speed = nanos_per_clock_cycle * cycles / wall_ns;
        print("sim(s) = {d:.3}; wall(s) = {d:.3}; speed-up factor: x{d}\n" ,.{
            sim_s,
            wall_s,
            speed,
        });
    }
}

const half_frame_cycles = clock_frequency / 120;
const first_interrupt_op = 0xCF;
const second_interrupt_op = 0xD7;
const flip_interrupt_op = first_interrupt_op ^ second_interrupt_op;

fn emulation_main_loop(comptime enable_trace: bool, state : *State) void {

    while (state.step <= state.config.max_steps) {

        if (state.cycle >= state.next_wakeup) {
            if (state.interrupts_enabled) {
                step_op(enable_trace, state, state.next_interrupt_op);
                state.step += 1;
            }
            state.next_wakeup += half_frame_cycles;
            state.next_interrupt_op ^= flip_interrupt_op;
        }
        const op = fetch(state);
        step_op(enable_trace, state, op);
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
    config : Config, //TODO: dont pass config as part of state
    buttons: Buttons,
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
        .buttons = .init,
        .step = 0,
        .cycle = 0,
        .mem = mem,
        .cpu = .init,
        .shifter = .init,
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
    const init = Cpu {
        .pc = 0, .sp = 0, .a = 0, .hl = 0,
        .b = 0, .c = 0, .d = 0, .e = 0,
        .flagS = 0, .flagZ = 0, .flagY = 0,
    };
};

const Shifter = struct {
    lo : u8,
    hi : u8,
    offset : u3,
    const init = Shifter { .lo = 0, .hi = 0, .offset = 0 };
};

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
    const buttons = state.buttons;
    switch (channel) {
        0x01 => {
            var res: u8 = 0;
            if (!buttons.coin_deposit) res |= 0x1; //inverted logic for coin_deposit
            if (buttons.two_player_start) res |= 0x2;
            if (buttons.one_player_start) res |= 0x4;
            //res |= 0x8;
            if (buttons.p1_fire) res |= 0x10;
            if (buttons.p1_left) res |= 0x20;
            if (buttons.p1_right) res |= 0x40;
            //print ("doIn: {d}\n",.{res});
            return res;
        },
        //TODO: input controls and dip switches on port 2
        0x02 => {
            return 0x00;
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

fn trace_op(comptime enable_trace: bool, state: *State, comptime fmt: []const u8, args: anytype) void {
    if (enable_trace) {
        if (state.step >= state.config.trace_from
                and state.step % state.config.trace_every == 0) {
            printTraceLine(state);
            print(fmt,args);
            if (state.config.trace_pixs) {
                print(" #pixs:{d}\n",.{count_on_pixels(state.mem)});
            } else {
                print("\n",.{});
            }
        }
    }
}

fn step_op(comptime enable_trace: bool, state : *State, op:u8) void {
    switch (op) {
        inline else => |ct_op| {
            step_ct_op(enable_trace, state, ct_op);
        }
    }
}

fn step_ct_op(comptime enable_trace: bool, state : *State, comptime op:u8) void {
    const cpu = &state.cpu;
    switch (op) {
        0x00 => {
            trace_op(enable_trace, state, "NOP",.{});
            state.cycle += 4;
        },
        0x01 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   BC,{X:0>4}", .{word});
            cpu.setBC(word);
            state.cycle += 10;
        },
        0x03 => {
            trace_op(enable_trace, state, "INC  BC", .{});
            cpu.setBC(1 + cpu.BC());
            state.cycle += 5;
        },
        0x04 => {
            trace_op(enable_trace, state, "INC  B", .{});
            const byte = increment(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x05 => {
            trace_op(enable_trace, state, "DEC  B", .{});
            const byte = decrement(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x06 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   B,{X:0>2}", .{byte});
            cpu.b = byte;
            state.cycle += 7;
        },
        0x07 => {
            trace_op(enable_trace, state, "RLCA", .{});
            const shunted : u1 = @truncate(cpu.a >> 7);
            cpu.a = cpu.a<<1 | shunted;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x09 => {
            trace_op(enable_trace, state, "ADD  HL,BC", .{});
            dad(cpu,cpu.BC());
            state.cycle += 10;
        },
        0x0A => {
            trace_op(enable_trace, state, "LD   A,(BC)", .{});
            cpu.a = state.mem[cpu.BC()];
            state.cycle += 7;
        },
        0x0C => {
            trace_op(enable_trace, state, "INC  C", .{});
            const byte = increment(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x0D => {
            trace_op(enable_trace, state, "DEC  C", .{});
            const byte = decrement(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x0E => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   C,{X:0>2}", .{byte});
            cpu.c = byte;
            state.cycle += 7;
        },
        0x0F => {
            trace_op(enable_trace, state, "RRCA", .{});
            const shunted : u1 = @truncate(cpu.a);
            cpu.a = @as(u8,shunted)<<7 | cpu.a>>1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x11 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   DE,{X:0>4}", .{word});
            cpu.setDE(word);
            state.cycle += 10;
        },
        0x12 => {
            trace_op(enable_trace, state, "LD   (DE),A", .{});
            var addr = cpu.DE();
            if (addr >= mem_size) addr -= 0x2000; //ram mirror
            state.mem[addr] = cpu.a;
            state.cycle += 7;
        },
        0x13 => {
            trace_op(enable_trace, state, "INC  DE", .{});
            cpu.setDE(1 + cpu.DE());
            state.cycle += 5;
        },
        0x14 => {
            trace_op(enable_trace, state, "INC  D", .{});
            const byte = increment(cpu.d);
            cpu.d = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x15 => {
            trace_op(enable_trace, state, "DEC  D", .{});
            const byte = decrement(cpu.d);
            cpu.d = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x16 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   D,{X:0>2}", .{byte});
            cpu.d = byte;
            state.cycle += 7;
        },
        0x19 => {
            trace_op(enable_trace, state, "ADD  HL,DE", .{});
            dad(cpu,cpu.DE());
            state.cycle += 10;
        },
        0x1A => {
            trace_op(enable_trace, state, "LD   A,(DE)", .{});
            cpu.a = state.mem[cpu.DE()];
            state.cycle += 7;
        },
        0x1B => {
            trace_op(enable_trace, state, "DEC  DE", .{});
            cpu.setDE(if (cpu.DE() == 0) 0xffff else cpu.DE() - 1);
            state.cycle += 5;
        },
        0x1F => {
            trace_op(enable_trace, state, "RAR", .{});
            const shunted : u1 = @truncate(cpu.a);
            cpu.a = @as(u8,cpu.flagY)<<7 | cpu.a>>1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x21 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   HL,{X:0>4}", .{word});
            cpu.hl = word;
            state.cycle += 10;
        },
        0x22 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   ({X:0>4}),HL", .{word});
            state.mem[word] = lo(cpu.hl);
            state.mem[word+1] = hi(cpu.hl);
            state.cycle += 16;
        },
        0x23 => {
            trace_op(enable_trace, state, "INC  HL", .{});
            cpu.hl += 1;
            state.cycle += 5;
        },
        0x26 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   H,{X:0>2}", .{byte});
            cpu.hl = hilo(byte,lo(cpu.hl));
            state.cycle += 7;
        },
        0x27 => {
            trace_op(enable_trace, state, "DAA", .{});
            print("DAA\n",.{});
            //TODO
            state.cycle += 4;
        },
        0x29 => {
            trace_op(enable_trace, state, "ADD  HL,HL", .{});
            dad(cpu,cpu.hl);
            state.cycle += 10;
        },
        0x2A => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   HL,({X:0>4})", .{word});
            cpu.hl = hilo (state.mem[word+1], state.mem[word]);
            state.cycle += 16;
        },
        0x2B => {
            trace_op(enable_trace, state, "DEC  HL", .{});
            cpu.hl = if (cpu.hl == 0) 0xffff else cpu.hl - 1;
            state.cycle += 5;
        },
        0x2C => {
            trace_op(enable_trace, state, "INC  L", .{});
            const byte = increment(lo(cpu.hl));
            cpu.hl = hilo(hi(cpu.hl),byte);
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x2E => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   L,{X:0>2}", .{byte});
            cpu.hl = hilo(hi(cpu.hl),byte);
            state.cycle += 7;
        },
        0x2F => {
            trace_op(enable_trace, state, "CPL", .{});
            cpu.a = ~ cpu.a;
            state.cycle += 4;
        },
        0x31 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   SP,{X:0>4}", .{word});
            cpu.sp = word;
            state.cycle += 10;
        },
        0x32 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   ({X:0>4}),A", .{word});
            state.mem[word] = cpu.a;
            state.cycle += 13;
        },
        0x34 => {
            trace_op(enable_trace, state, "INC  (HL)", .{});
            const byte = increment(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu,byte);
            state.cycle += 10;
        },
        0x35 => {
            trace_op(enable_trace, state, "DEC  (HL)", .{});
            const byte = decrement(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu,byte);
            state.cycle += 10;
        },
        0x36 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   (HL),{X:0>2}", .{byte});
            state.mem[cpu.hl] = byte;
            state.cycle += 10;
        },
        0x37 => {
            trace_op(enable_trace, state, "SCF", .{});
            cpu.flagY = 1;
            state.cycle += 4;
        },
        0x3A => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "LD   A,({X:0>4})", .{word});
            cpu.a = state.mem[word];
            state.cycle += 13;
        },
        0x3C => {
            trace_op(enable_trace, state, "INC  A", .{});
            const byte = increment(cpu.a);
            cpu.a = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x3D => {
            trace_op(enable_trace, state, "DEC  A", .{});
            const byte = decrement(cpu.a);
            cpu.a = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x3E => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "LD   A,{X:0>2}", .{byte});
            cpu.a = byte;
            state.cycle += 7;
        },
        0x41 => {
            trace_op(enable_trace, state, "LD   B,C", .{});
            cpu.b = cpu.c;
            state.cycle += 5;
        },
        0x46 => {
            trace_op(enable_trace, state, "LD   B,(HL)", .{});
            cpu.b = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x47 => {
            trace_op(enable_trace, state, "LD   B,A", .{});
            cpu.b = cpu.a;
            state.cycle += 5;
        },
        0x48 => {
            trace_op(enable_trace, state, "LD   C,B", .{});
            cpu.c = cpu.b;
            state.cycle += 5;
        },
        0x4E => {
            trace_op(enable_trace, state, "LD   C,(HL)", .{});
            cpu.c = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x4F => {
            trace_op(enable_trace, state, "LD   C,A", .{});
            cpu.c = cpu.a;
            state.cycle += 5;
        },
        0x56 => {
            trace_op(enable_trace, state, "LD   D,(HL)", .{});
            cpu.d = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x57 => {
            trace_op(enable_trace, state, "LD   D,A", .{});
            cpu.d = cpu.a;
            state.cycle += 5;
        },
        0x5E => {
            trace_op(enable_trace, state, "LD   E,(HL)", .{});
            cpu.e = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x5F => {
            trace_op(enable_trace, state, "LD   E,A", .{});
            cpu.e = cpu.a;
            state.cycle += 5;
        },
        0x61 => {
            trace_op(enable_trace, state, "LD   H,C", .{});
            cpu.hl = hilo(cpu.c,lo(cpu.hl));
            state.cycle += 5;
        },
        0x65 => {
            trace_op(enable_trace, state, "LD   H,L", .{});
            cpu.hl = hilo(lo(cpu.hl),lo(cpu.hl));
            state.cycle += 5;
        },
        0x66 => {
            trace_op(enable_trace, state, "LD   H,(HL)", .{});
            cpu.hl = hilo(state.mem[cpu.hl],lo(cpu.hl));
            state.cycle += 7;
        },
        0x67 => {
            trace_op(enable_trace, state, "LD   H,A", .{});
            cpu.hl = hilo(cpu.a,lo(cpu.hl));
            state.cycle += 5;
        },
        0x68 => {
            trace_op(enable_trace, state, "LD   L,B", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.b);
            state.cycle += 5;
        },
        0x69 => {
            trace_op(enable_trace, state, "LD   L,C", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.c);
            state.cycle += 5;
        },
        0x6F => {
            trace_op(enable_trace, state, "LD   L,A", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.a);
            state.cycle += 5;
        },
        0x70 => {
            trace_op(enable_trace, state, "LD   (HL),B", .{});
            state.mem[cpu.hl] = cpu.b;
            state.cycle += 7;
        },
        0x71 => {
            trace_op(enable_trace, state, "LD   (HL),C", .{});
            state.mem[cpu.hl] = cpu.c;
            state.cycle += 7;
        },
        0x77 => {
            trace_op(enable_trace, state, "LD   (HL),A", .{});
            var addr = cpu.hl;
            if (addr >= mem_size) addr -= 0x2000; //ram mirror
            state.mem[addr] = cpu.a;
            state.cycle += 7;
        },
        0x78 => {
            trace_op(enable_trace, state, "LD   A,B", .{});
            cpu.a = cpu.b;
            state.cycle += 5;
        },
        0x79 => {
            trace_op(enable_trace, state, "LD   A,C", .{});
            cpu.a = cpu.c;
            state.cycle += 5;
        },
        0x7A => {
            trace_op(enable_trace, state, "LD   A,D", .{});
            cpu.a = cpu.d;
            state.cycle += 5;
        },
        0x7B => {
            trace_op(enable_trace, state, "LD   A,E", .{});
            cpu.a = cpu.e;
            state.cycle += 5;
        },
        0x7C => {
            trace_op(enable_trace, state, "LD   A,H", .{});
            cpu.a = hi(cpu.hl);
            state.cycle += 5;
        },
        0x7D => {
            trace_op(enable_trace, state, "LD   A,L", .{});
            cpu.a = lo(cpu.hl);
            state.cycle += 5;
        },
        0x7E => {
            trace_op(enable_trace, state, "LD   A,(HL)", .{});
            cpu.a = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x80 => {
            trace_op(enable_trace, state, "ADD  B", .{});
            add_with_carry(cpu, cpu.b, 0);
            state.cycle += 4;
        },
        0x81 => {
            trace_op(enable_trace, state, "ADD  C", .{});
            add_with_carry(cpu, cpu.c, 0);
            state.cycle += 4;
        },
        0x83 => {
            trace_op(enable_trace, state, "ADD  E", .{});
            add_with_carry(cpu, cpu.e, 0);
            state.cycle += 4;
        },
        0x85 => {
            trace_op(enable_trace, state, "ADD  L", .{});
            add_with_carry(cpu, lo(cpu.hl), 0);
            state.cycle += 4;
        },
        0x86 => {
            trace_op(enable_trace, state, "ADD  (HL)", .{});
            add_with_carry(cpu, state.mem[cpu.hl], 0);
            state.cycle += 7;
        },
        0x8A => {
            trace_op(enable_trace, state, "ADC  D", .{});
            add_with_carry(cpu, cpu.d, cpu.flagY);
            state.cycle += 4;
        },
        0x97 => {
            trace_op(enable_trace, state, "SUB  A", .{});
            cpu.a = subtract_with_borrow(cpu,cpu.a,cpu.a,0);
            state.cycle += 4;
        },
        0xA0 => {
            trace_op(enable_trace, state, "AND  B", .{});
            const res = cpu.a & cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA6 => {
            trace_op(enable_trace, state, "AND  (HL)", .{});
            const res = cpu.a & state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xA7 => {
            trace_op(enable_trace, state, "AND  A", .{});
            const res = cpu.a & cpu.a;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA8 => {
            trace_op(enable_trace, state, "XOR  B", .{});
            const res = cpu.a ^ cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAF => {
            trace_op(enable_trace, state, "XOR  A", .{});
            const res = cpu.a ^ cpu.a;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB0 => {
            trace_op(enable_trace, state, "OR   B", .{});
            const res = cpu.a | cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB4 => {
            trace_op(enable_trace, state, "OR   H", .{});
            const res = cpu.a | hi(cpu.hl);
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB6 => {
            trace_op(enable_trace, state, "OR   (HL)", .{});
            const res = cpu.a | state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xB8 => {
            trace_op(enable_trace, state, "CP   B", .{});
            _ = subtract_with_borrow(cpu,cpu.a,cpu.b,0);
            state.cycle += 4;
        },
        0xBC => {
            trace_op(enable_trace, state, "CP   H", .{});
            _ = subtract_with_borrow(cpu,cpu.a,hi(cpu.hl),0);
            state.cycle += 4;
        },
        0xBE => {
            trace_op(enable_trace, state, "CP   (HL)", .{});
            _ = subtract_with_borrow(cpu,cpu.a,state.mem[cpu.hl],0);
            state.cycle += 7;
        },
        0xC0 => {
            trace_op(enable_trace, state, "RET  NZ", .{});
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
            trace_op(enable_trace, state, "POP  BC", .{});
            cpu.c = popStack(state);
            cpu.b = popStack(state);
            state.cycle += 10;
        },
        0xC2 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "JP   NZ,{X:0>4}", .{word});
            if (cpu.flagZ == 0) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xC3 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "JP   {X:0>4}", .{word});
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC4 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "CALL NZ,{X:0>4}", .{word});
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
            trace_op(enable_trace, state, "PUSH BC", .{});
            pushStack(state,cpu.b);
            pushStack(state,cpu.c);
            state.cycle += 11;
        },
        0xC6 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "ADD  {X:0>2}", .{byte});
            add_with_carry(cpu, byte, 0);
            state.cycle += 7;
        },
        0xC8 => {
            trace_op(enable_trace, state, "RET  Z", .{});
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
            trace_op(enable_trace, state, "RET", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.pc = hilo(a,b);
            state.cycle += 10;
        },
        0xCA => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "JP   Z,{X:0>4}", .{word});
            if (cpu.flagZ == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xCC => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "CALL Z,{X:0>4}", .{word});
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
            trace_op(enable_trace, state, "CALL {X:0>4}", .{word});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = word;
            state.cycle += 17;
        },
        0xCF => {
            trace_op(enable_trace, state, "RST  1", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x08;
            state.cycle += 4;
        },
        0xD0 => {
            trace_op(enable_trace, state, "RET  NC", .{});
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
            trace_op(enable_trace, state, "POP  DE", .{});
            cpu.e = popStack(state);
            cpu.d = popStack(state);
            state.cycle += 10;
        },
        0xD2 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "JP   NC,{X:0>4}", .{word});
            if (cpu.flagY == 0) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xD3 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "OUT  {X:0>2}", .{byte});
            doOut(state,byte,cpu.a);
            state.cycle += 10;
        },
        0xD4 => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "CALL NC,{X:0>4}", .{word});
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
            trace_op(enable_trace, state, "PUSH DE", .{});
            pushStack(state,cpu.d);
            pushStack(state,cpu.e);
            state.cycle += 11;
        },
        0xD6 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "SUB  {X:0>2}", .{byte});
            cpu.a = subtract_with_borrow(cpu,cpu.a,byte,0);
            state.cycle += 7;
        },
        0xD7 => {
            trace_op(enable_trace, state, "RST  2", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x10;
            state.cycle += 4;
        },
        0xD8 => {
            trace_op(enable_trace, state, "RET  CY", .{});
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
            trace_op(enable_trace, state, "JP   CY,{X:0>4}", .{word});
            if (cpu.flagY == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xDB => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "IN   {X:0>2}", .{byte});
            cpu.a = doIn(state,byte);
            state.cycle += 10;
        },
        0xDE => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "SBC  {X:0>2}", .{byte});
            cpu.a = subtract_with_borrow(cpu,cpu.a,byte,cpu.flagY);
            state.cycle += 7;
        },
        0xE1 => {
            trace_op(enable_trace, state, "POP  HL", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.hl = hilo(a,b);
            state.cycle += 10;
        },
        0xE3 => {
            trace_op(enable_trace, state, "EX   (SP),HL", .{});
            const b = state.mem[state.cpu.sp];
            const a = state.mem[state.cpu.sp+1];
            state.mem[state.cpu.sp] = lo(cpu.hl);
            state.mem[state.cpu.sp+1] = hi(cpu.hl);
            cpu.hl = hilo(a,b);
            state.cycle += 18;
        },
        0xE5 => {
            trace_op(enable_trace, state, "PUSH HL", .{});
            pushStack(state,hi(cpu.hl));
            pushStack(state,lo(cpu.hl));
            state.cycle += 11;
        },
        0xE6 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "AND  {X:0>2}", .{byte});
            const res = cpu.a & byte;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xE9 => {
            trace_op(enable_trace, state, "JP   (HL)", .{});
            cpu.pc = cpu.hl;
            state.cycle += 5;
        },
        0xEB => {
            trace_op(enable_trace, state, "EX   DE,HL", .{});
            const de = cpu.DE();
            cpu.setDE(cpu.hl);
            cpu.hl = de;
            state.cycle += 4;
        },
        0xF1 => {
            trace_op(enable_trace, state, "POP  PSW", .{});
            cpu.restoreFlags(popStack(state));
            cpu.a = popStack(state);
            state.cycle += 10;
        },
        0xF5 => {
            trace_op(enable_trace, state, "PUSH PSW", .{});
            pushStack(state,cpu.a);
            pushStack(state,cpu.saveFlags());
            state.cycle += 11;
        },
        0xF6 => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "OR   {X:0>2}", .{byte});
            const res = cpu.a | byte;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xFA => {
            const word = fetch16(state);
            trace_op(enable_trace, state, "JP   MI,{X:0>4}", .{word});
            if (cpu.flagS == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xFB => {
            trace_op(enable_trace, state, "EI", .{});
            state.interrupts_enabled = true;
            state.cycle += 4;
        },
        0xFE => {
            const byte = fetch(state);
            trace_op(enable_trace, state, "CP   {X:0>2}", .{byte});
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


const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const render_scale = 3;

const pixel_w = 224;
const pixel_h = 256;

const video_mem_size = 7 * 1024;
var video_mem = [_]u8{0} ** video_mem_size;

fn my_draw_picture(renderer: *c.SDL_Renderer, state: *State) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 40, 255);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    var counter : usize = 0x2400;
    for (0..pixel_w) |y| {
        for (0..pixel_h/8) |xi| {
            const byte = state.mem[counter];
            counter += 1;
            for (0..8) |i| {
                const x = xi * 8 + i;
                const on = ((byte >> @intCast(i)) & 1) == 1;
                if (on) {
                    const rect = c.SDL_Rect {
                        .x = @intCast(y * render_scale),
                        .y = @intCast( (255-x) * render_scale),
                        .w = render_scale,
                        .h = render_scale,
                    };
                    _ = c.SDL_RenderFillRect(renderer, &rect);
                }
            }
        }
    }
}

pub fn graphics_main(state: *State) !void {

    state.config.max_steps = 0;

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const screen_w = render_scale * pixel_w;
    const screen_h = render_scale * pixel_h;

    const screen = c.SDL_CreateWindow(
        "Soon to be Space Invaders",
        200, //c.SDL_WINDOWPOS_UNDEFINED,
        50, //c.SDL_WINDOWPOS_UNDEFINED,
        screen_w,
        screen_h,
        c.SDL_WINDOW_OPENGL
    ) orelse {
        c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(screen);

    const renderer = c.SDL_CreateRenderer(screen, -1, 0) orelse {
        c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    print("starting event loop\n",.{});
    var quit = false;
    var frame : usize = 0;
    const tic = mono_clock_ns();
    var max_cycles : u64 = 0;
    const speed_up_factor : i32 = 1;

    while (!quit) {

        var buf: [16]u8 = undefined;
        //_ = try std.fmt.bufPrint(&buf, "x{d}\x00", .{speed_up_factor});
        _ = try std.fmt.bufPrint(&buf, "frame: {d}\x00", .{frame});
        c.SDL_SetWindowTitle(screen,&buf);

        my_draw_picture(renderer,state);
        c.SDL_RenderPresent(renderer);

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            //print("{any}\n",.{event});
            process_event(event, &state.buttons, &quit);
        }

        const cycles_per_display_frame = if (speed_up_factor < 0) 0 else
            2 * half_frame_cycles * @as(u32,@intCast(speed_up_factor));

        frame+=1;
        max_cycles += cycles_per_display_frame;
        graphics_emulation_main_loop(state, max_cycles);

        const toc = mono_clock_ns();
        const wall_ns : u64 = toc - tic;
        const wall_s = @as(f32,@floatFromInt(wall_ns)) / billion;

        const desired_display_fps = 60;
        const desired_s : f32 =
            @as(f32,@floatFromInt(frame))
            / @as(f32,@floatFromInt(desired_display_fps));

        const pause_ms : i32 = @intFromFloat((desired_s - wall_s) * 1000);
        //print("{d} ",.{pause_ms});
        if (pause_ms > 0) {
            c.SDL_Delay(@intCast(pause_ms));
        }

        // uncomment to go as fast as possible
        //speed_up_factor = speed_up_factor + pause_ms; //increase or decrease or leave alone

    }
    print("event loop ended\n",.{});
}


fn graphics_emulation_main_loop(state : *State, max_cycles: u64) void {
    const enable_trace = false;

    while (state.cycle <= max_cycles) {

        if (state.cycle >= state.next_wakeup) {
            if (state.interrupts_enabled) {
                step_op(enable_trace, state, state.next_interrupt_op);
                state.step += 1;
            }
            state.next_wakeup += half_frame_cycles;
            state.next_interrupt_op ^= flip_interrupt_op;
        }
        const op = fetch(state);
        step_op(enable_trace, state, op);
        state.step += 1;
    }
}

const Buttons = struct {
    coin_deposit: bool,
    one_player_start: bool,
    two_player_start: bool,
    p1_left : bool,
    p1_right : bool,
    p1_fire : bool,

    const init = Buttons {
        .coin_deposit = false,
        .one_player_start = false,
        .two_player_start = false,
        .p1_left = false,
        .p1_right = false,
        .p1_fire = false,
    };
};

fn process_event(event: c.SDL_Event, buttons: *Buttons, quit: *bool) void {
    const sym = event.key.keysym.sym;
    switch (event.type) {
        c.SDL_KEYDOWN => {
            //print("down:sym={d}\n",.{sym});
            if (sym == c.SDLK_ESCAPE) quit.* = true;
            process_sym(sym, buttons, true);
        },
        c.SDL_KEYUP => {
            //print("up:sym={d}\n",.{sym});
            process_sym(sym, buttons, false);
        },
        c.SDL_QUIT => {
            quit.* = true;
        },
        else => {},
    }
}

fn process_sym(sym: i32, buttons: *Buttons, pressed: bool) void {
    if (sym == c.SDLK_INSERT) buttons.coin_deposit = pressed;
    if (sym == c.SDLK_F1) buttons.one_player_start = pressed;
    if (sym == c.SDLK_F2) buttons.two_player_start = pressed;
    if (sym == c.SDLK_RETURN) buttons.p1_fire = pressed;
    if (sym == 'z') buttons.p1_left = pressed;
    if (sym == 'x') buttons.p1_right = pressed;
}
