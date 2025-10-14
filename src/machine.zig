const std = @import("std");
const debug = std.debug;
const print = debug.print;
const native_endian = @import("builtin").target.cpu.arch.endian();
const two_million = 2_000_000;
const fps = 60;

pub const clock_frequency = two_million; // of the 8080 CPU being simulated
pub const mem_size = 16 * 1024;
pub const half_frame_cycles = clock_frequency / (2 * fps);

pub const Buttons = struct {
    coin_deposit: bool,
    one_player_start: bool,
    two_player_start: bool,
    p1_left: bool,
    p1_right: bool,
    p1_fire: bool,

    pub const init = Buttons{
        .coin_deposit = false,
        .one_player_start = false,
        .two_player_start = false,
        .p1_left = false,
        .p1_right = false,
        .p1_fire = false,
    };
};

pub const State = struct {
    buttons: Buttons,
    icount: u64, //count of instructions executed
    cycle: u64, //count of simulated cycles (at clock speed of 2 MhZ)
    mem: []u8,
    cpu: Cpu,
    shifter: Shifter,
    interrupts_enabled: bool,
    next_wakeup: u64,
    next_interrupt_op: u8,
};

pub fn init_state(mem: []u8) State {
    const state: State = State{
        .buttons = .init,
        .icount = 0,
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

const first_interrupt_op = 0xCF;
const second_interrupt_op = 0xD7;
const flip_interrupt_op = first_interrupt_op ^ second_interrupt_op;

pub const Tracer = fn (*State, comptime []const u8, anytype) void;

pub fn step(comptime tracer: Tracer, state: *State) void {
    if (state.cycle >= state.next_wakeup) {
        if (state.interrupts_enabled) {
            step_op(tracer, state, state.next_interrupt_op);
            state.icount += 1;
        }
        state.next_wakeup += half_frame_cycles;
        state.next_interrupt_op ^= flip_interrupt_op;
    }
    const op = fetch(state);
    step_op(tracer, state, op);
    state.icount += 1;
}

fn step_op(comptime tracer: Tracer, state: *State, op: u8) void {
    switch (op) {
        inline else => |ct_op| {
            step_ct_op(tracer, state, ct_op);
        },
    }
}

fn step_ct_op(comptime tracer: Tracer, state: *State, comptime op: u8) void {
    const cpu = &state.cpu;
    switch (op) {
        0x00 => {
            op0(tracer, state, "NOP");
            state.cycle += 4;
        },
        0x01 => {
            const word = op2(tracer, state, "LD   BC,");
            cpu.setBC(word);
            state.cycle += 10;
        },
        0x03 => {
            op0(tracer, state, "INC  BC");
            cpu.setBC(1 +% cpu.BC());
            state.cycle += 5;
        },
        0x04 => {
            op0(tracer, state, "INC  B");
            const byte = increment(cpu.b);
            cpu.b = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x05 => {
            op0(tracer, state, "DEC  B");
            const byte = decrement(cpu.b);
            cpu.b = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x06 => {
            const byte = op1(tracer, state, "LD   B,");
            cpu.b = byte;
            state.cycle += 7;
        },
        0x07 => {
            op0(tracer, state, "RLCA");
            const shunted: u1 = @truncate(cpu.a >> 7);
            cpu.a = cpu.a << 1 | shunted;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x09 => {
            op0(tracer, state, "ADD  HL,BC");
            dad(cpu, cpu.BC());
            state.cycle += 10;
        },
        0x0A => {
            op0(tracer, state, "LD   A");
            cpu.a = state.mem[cpu.BC()];
            state.cycle += 7;
        },
        0x0C => {
            op0(tracer, state, "INC  C");
            const byte = increment(cpu.c);
            cpu.c = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x0D => {
            op0(tracer, state, "DEC  C");
            const byte = decrement(cpu.c);
            cpu.c = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x0E => {
            const byte = op1(tracer, state, "LD   C,");
            cpu.c = byte;
            state.cycle += 7;
        },
        0x0F => {
            op0(tracer, state, "RRCA");
            const shunted: u1 = @truncate(cpu.a);
            cpu.a = @as(u8, shunted) << 7 | cpu.a >> 1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x11 => {
            const word = op2(tracer, state, "LD   DE,");
            cpu.setDE(word);
            state.cycle += 10;
        },
        0x12 => {
            op0(tracer, state, "LD   (DE),A");
            var addr = cpu.DE();
            if (addr >= mem_size) addr -= 0x2000; //ram mirror
            state.mem[addr] = cpu.a;
            state.cycle += 7;
        },
        0x13 => {
            op0(tracer, state, "INC  DE");
            cpu.setDE(1 +% cpu.DE());
            state.cycle += 5;
        },
        0x14 => {
            op0(tracer, state, "INC  D");
            const byte = increment(cpu.d);
            cpu.d = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x15 => {
            op0(tracer, state, "DEC  D");
            const byte = decrement(cpu.d);
            cpu.d = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x16 => {
            const byte = op1(tracer, state, "LD   D,");
            cpu.d = byte;
            state.cycle += 7;
        },
        0x19 => {
            op0(tracer, state, "ADD  HL,DE");
            dad(cpu, cpu.DE());
            state.cycle += 10;
        },
        0x1A => {
            op0(tracer, state, "LD   A,(DE)");
            cpu.a = state.mem[cpu.DE()];
            state.cycle += 7;
        },
        0x1B => {
            op0(tracer, state, "DEC  DE");
            cpu.setDE(cpu.DE() -% 1);
            state.cycle += 5;
        },
        0x1C => {
            op0(tracer, state, "INC  E");
            const byte = increment(cpu.e);
            cpu.e = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x1D => {
            op0(tracer, state, "DEC  E");
            const byte = decrement(cpu.e);
            cpu.e = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x1E => {
            const byte = op1(tracer, state, "LD   E,");
            cpu.e = byte;
            state.cycle += 7;
        },
        0x1F => {
            op0(tracer, state, "RAR");
            const shunted: u1 = @truncate(cpu.a);
            cpu.a = @as(u8, cpu.flagY) << 7 | cpu.a >> 1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x21 => {
            const word = op2(tracer, state, "LD   HL,");
            cpu.hl = word;
            state.cycle += 10;
        },
        0x22 => {
            var word = op2g(tracer, state, "LD   ({X:0>4})");
            if (word >= mem_size) {
                //word -= 0x2000; //ram mirror
                const masked = word & 0x3fff;
                print("OOB: {X:0>4} --> {X:0>4}\n", .{ word, masked });
                word = masked;
            }
            state.mem[word] = lo(cpu.hl);
            state.mem[word + 1] = hi(cpu.hl);
            state.cycle += 16;
        },
        0x23 => {
            op0(tracer, state, "INC  HL");
            cpu.hl +%= 1;
            state.cycle += 5;
        },
        0x24 => {
            op0(tracer, state, "INC  H");
            const byte = increment(hi(cpu.hl));
            cpu.hl = hilo(byte, lo(cpu.hl));
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x25 => {
            op0(tracer, state, "DEC  H");
            const byte = decrement(hi(cpu.hl));
            cpu.hl = hilo(byte, lo(cpu.hl));
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x26 => {
            const byte = op1(tracer, state, "LD   H,");
            cpu.hl = hilo(byte, lo(cpu.hl));
            state.cycle += 7;
        },
        0x27 => {
            op0(tracer, state, "DAA");
            print("DAA\n", .{});
            //TODO
            state.cycle += 4;
        },
        0x29 => {
            op0(tracer, state, "ADD  HL,HL");
            dad(cpu, cpu.hl);
            state.cycle += 10;
        },
        0x2A => {
            const word = op2(tracer, state, "LD   HL");
            cpu.hl = hilo(state.mem[word + 1], state.mem[word]);
            state.cycle += 16;
        },
        0x2B => {
            op0(tracer, state, "DEC  HL");
            cpu.hl = cpu.hl -% 1;
            state.cycle += 5;
        },
        0x2C => {
            op0(tracer, state, "INC  L");
            const byte = increment(lo(cpu.hl));
            cpu.hl = hilo(hi(cpu.hl), byte);
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x2D => {
            op0(tracer, state, "DEC  L");
            const byte = decrement(lo(cpu.hl));
            cpu.hl = hilo(hi(cpu.hl), byte);
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x2E => {
            const byte = op1(tracer, state, "LD   L,");
            cpu.hl = hilo(hi(cpu.hl), byte);
            state.cycle += 7;
        },
        0x2F => {
            op0(tracer, state, "CPL");
            cpu.a = ~cpu.a;
            state.cycle += 4;
        },
        0x31 => {
            const word = op2(tracer, state, "LD   SP,");
            cpu.sp = word;
            state.cycle += 10;
        },
        0x32 => {
            const word = op2g(tracer, state, "LD   ({X:0>4}),A");
            state.mem[word] = cpu.a;
            state.cycle += 13;
        },
        0x34 => {
            op0(tracer, state, "INC  (HL)");
            const byte = increment(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu, byte);
            state.cycle += 10;
        },
        0x35 => {
            op0(tracer, state, "DEC  (HL)");
            const byte = decrement(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu, byte);
            state.cycle += 10;
        },
        0x36 => {
            const byte = op1(tracer, state, "LD   (HL),");
            state.mem[cpu.hl] = byte;
            state.cycle += 10;
        },
        0x37 => {
            op0(tracer, state, "SCF");
            cpu.flagY = 1;
            state.cycle += 4;
        },
        0x3A => {
            const word = op2g(tracer, state, "LD   A,({X:0>4})");
            cpu.a = state.mem[word];
            state.cycle += 13;
        },
        0x3C => {
            op0(tracer, state, "INC  A");
            const byte = increment(cpu.a);
            cpu.a = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x3D => {
            op0(tracer, state, "DEC  A");
            const byte = decrement(cpu.a);
            cpu.a = byte;
            setFlags(cpu, byte);
            state.cycle += 5;
        },
        0x3E => {
            const byte = op1(tracer, state, "LD   A,");
            cpu.a = byte;
            state.cycle += 7;
        },
        0x41 => {
            op0(tracer, state, "LD   B,C");
            cpu.b = cpu.c;
            state.cycle += 5;
        },
        0x42 => {
            op0(tracer, state, "LD   B,D");
            cpu.b = cpu.d;
            state.cycle += 5;
        },
        0x43 => {
            op0(tracer, state, "LD   B,E");
            cpu.b = cpu.e;
            state.cycle += 5;
        },
        0x44 => {
            op0(tracer, state, "LD   B,H");
            cpu.b = hi(cpu.hl);
            state.cycle += 5;
        },
        0x45 => {
            op0(tracer, state, "LD   B,L");
            cpu.b = lo(cpu.hl);
            state.cycle += 5;
        },
        0x46 => {
            op0(tracer, state, "LD   B,(HL)");
            cpu.b = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x47 => {
            op0(tracer, state, "LD   B,A");
            cpu.b = cpu.a;
            state.cycle += 5;
        },
        0x48 => {
            op0(tracer, state, "LD   C,B");
            cpu.c = cpu.b;
            state.cycle += 5;
        },
        0x4A => {
            op0(tracer, state, "LD   C,D");
            cpu.c = cpu.d;
            state.cycle += 5;
        },
        0x4B => {
            op0(tracer, state, "LD   C,E");
            cpu.c = cpu.e;
            state.cycle += 5;
        },
        0x4C => {
            op0(tracer, state, "LD   C,H");
            cpu.c = hi(cpu.hl);
            state.cycle += 5;
        },
        0x4D => {
            op0(tracer, state, "LD   C,L");
            cpu.c = lo(cpu.hl);
            state.cycle += 5;
        },
        0x4E => {
            op0(tracer, state, "LD   C,(HL)");
            cpu.c = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x4F => {
            op0(tracer, state, "LD   C,A");
            cpu.c = cpu.a;
            state.cycle += 5;
        },
        0x50 => {
            op0(tracer, state, "LD   D,B");
            cpu.d = cpu.b;
            state.cycle += 5;
        },
        0x51 => {
            op0(tracer, state, "LD   D,C");
            cpu.d = cpu.c;
            state.cycle += 5;
        },
        0x53 => {
            op0(tracer, state, "LD   D,E");
            cpu.d = cpu.e;
            state.cycle += 5;
        },
        0x54 => {
            op0(tracer, state, "LD   D,H");
            cpu.d = hi(cpu.hl);
            state.cycle += 5;
        },
        0x55 => {
            op0(tracer, state, "LD   D,L");
            cpu.d = lo(cpu.hl);
            state.cycle += 5;
        },
        0x56 => {
            op0(tracer, state, "LD   D,(HL)");
            cpu.d = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x57 => {
            op0(tracer, state, "LD   D,A");
            cpu.d = cpu.a;
            state.cycle += 5;
        },
        0x58 => {
            op0(tracer, state, "LD   E,B");
            cpu.e = cpu.b;
            state.cycle += 5;
        },
        0x59 => {
            op0(tracer, state, "LD   E,C");
            cpu.e = cpu.c;
            state.cycle += 5;
        },
        0x5A => {
            op0(tracer, state, "LD   E,D");
            cpu.e = cpu.d;
            state.cycle += 5;
        },
        0x5C => {
            op0(tracer, state, "LD   E,H");
            cpu.e = hi(cpu.hl);
            state.cycle += 5;
        },
        0x5D => {
            op0(tracer, state, "LD   E,L");
            cpu.e = lo(cpu.hl);
            state.cycle += 5;
        },
        0x5E => {
            op0(tracer, state, "LD   E,(HL)");
            cpu.e = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x5F => {
            op0(tracer, state, "LD   E,A");
            cpu.e = cpu.a;
            state.cycle += 5;
        },
        0x60 => {
            op0(tracer, state, "LD   H,B");
            cpu.hl = hilo(cpu.b, lo(cpu.hl));
            state.cycle += 5;
        },
        0x61 => {
            op0(tracer, state, "LD   H,C");
            cpu.hl = hilo(cpu.c, lo(cpu.hl));
            state.cycle += 5;
        },
        0x62 => {
            op0(tracer, state, "LD   H,D");
            cpu.hl = hilo(cpu.d, lo(cpu.hl));
            state.cycle += 5;
        },
        0x63 => {
            op0(tracer, state, "LD   H,E");
            cpu.hl = hilo(cpu.e, lo(cpu.hl));
            state.cycle += 5;
        },
        0x65 => {
            op0(tracer, state, "LD   H,L");
            cpu.hl = hilo(lo(cpu.hl), lo(cpu.hl));
            state.cycle += 5;
        },
        0x66 => {
            op0(tracer, state, "LD   H,(HL)");
            cpu.hl = hilo(state.mem[cpu.hl], lo(cpu.hl));
            state.cycle += 7;
        },
        0x67 => {
            op0(tracer, state, "LD   H,A");
            cpu.hl = hilo(cpu.a, lo(cpu.hl));
            state.cycle += 5;
        },
        0x68 => {
            op0(tracer, state, "LD   L,B");
            cpu.hl = hilo(hi(cpu.hl), cpu.b);
            state.cycle += 5;
        },
        0x69 => {
            op0(tracer, state, "LD   L,C");
            cpu.hl = hilo(hi(cpu.hl), cpu.c);
            state.cycle += 5;
        },
        0x6A => {
            op0(tracer, state, "LD   L,D");
            cpu.hl = hilo(hi(cpu.hl), cpu.d);
            state.cycle += 5;
        },
        0x6B => {
            op0(tracer, state, "LD   L,E");
            cpu.hl = hilo(hi(cpu.hl), cpu.e);
            state.cycle += 5;
        },
        0x6C => {
            op0(tracer, state, "LD   L,H");
            cpu.hl = hilo(hi(cpu.hl), hi(cpu.hl));
            state.cycle += 5;
        },
        0x6E => {
            op0(tracer, state, "LD   L,(HL)");
            cpu.hl = hilo(hi(cpu.hl), state.mem[cpu.hl]);
            state.cycle += 7;
        },
        0x6F => {
            op0(tracer, state, "LD   L,A");
            cpu.hl = hilo(hi(cpu.hl), cpu.a);
            state.cycle += 5;
        },
        0x70 => {
            op0(tracer, state, "LD   (HL),B");
            state.mem[cpu.hl] = cpu.b;
            state.cycle += 7;
        },
        0x71 => {
            op0(tracer, state, "LD   (HL),C");
            state.mem[cpu.hl] = cpu.c;
            state.cycle += 7;
        },
        0x72 => {
            op0(tracer, state, "LD   (HL),D");
            state.mem[cpu.hl] = cpu.d;
            state.cycle += 7;
        },
        0x73 => {
            op0(tracer, state, "LD   (HL),E");
            state.mem[cpu.hl] = cpu.e;
            state.cycle += 7;
        },
        0x74 => {
            op0(tracer, state, "LD   (HL),H");
            state.mem[cpu.hl] = hi(cpu.hl);
            state.cycle += 7;
        },
        0x75 => {
            op0(tracer, state, "LD   (HL),L");
            state.mem[cpu.hl] = lo(cpu.hl);
            state.cycle += 7;
        },
        0x77 => {
            op0(tracer, state, "LD   (HL),A");
            var addr = cpu.hl;
            if (addr >= mem_size) addr -= 0x2000; //ram mirror
            state.mem[addr] = cpu.a;
            state.cycle += 7;
        },
        0x78 => {
            op0(tracer, state, "LD   A,B");
            cpu.a = cpu.b;
            state.cycle += 5;
        },
        0x79 => {
            op0(tracer, state, "LD   A,C");
            cpu.a = cpu.c;
            state.cycle += 5;
        },
        0x7A => {
            op0(tracer, state, "LD   A,D");
            cpu.a = cpu.d;
            state.cycle += 5;
        },
        0x7B => {
            op0(tracer, state, "LD   A,E");
            cpu.a = cpu.e;
            state.cycle += 5;
        },
        0x7C => {
            op0(tracer, state, "LD   A,H");
            cpu.a = hi(cpu.hl);
            state.cycle += 5;
        },
        0x7D => {
            op0(tracer, state, "LD   A,L");
            cpu.a = lo(cpu.hl);
            state.cycle += 5;
        },
        0x7E => {
            op0(tracer, state, "LD   A,(HL)");
            cpu.a = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x80 => {
            op0(tracer, state, "ADD  B");
            add_with_carry(cpu, cpu.b, 0);
            state.cycle += 4;
        },
        0x81 => {
            op0(tracer, state, "ADD  C");
            add_with_carry(cpu, cpu.c, 0);
            state.cycle += 4;
        },
        0x82 => {
            op0(tracer, state, "ADD  D");
            add_with_carry(cpu, cpu.d, 0);
            state.cycle += 4;
        },
        0x83 => {
            op0(tracer, state, "ADD  E");
            add_with_carry(cpu, cpu.e, 0);
            state.cycle += 4;
        },
        0x84 => {
            op0(tracer, state, "ADD  H");
            add_with_carry(cpu, hi(cpu.hl), 0);
            state.cycle += 4;
        },
        0x85 => {
            op0(tracer, state, "ADD  L");
            add_with_carry(cpu, lo(cpu.hl), 0);
            state.cycle += 4;
        },
        0x86 => {
            op0(tracer, state, "ADD  (HL)");
            add_with_carry(cpu, state.mem[cpu.hl], 0);
            state.cycle += 7;
        },
        0x87 => {
            op0(tracer, state, "ADD  A");
            add_with_carry(cpu, cpu.a, 0);
            state.cycle += 4;
        },
        0x88 => {
            op0(tracer, state, "ADC  B");
            add_with_carry(cpu, cpu.b, cpu.flagY);
            state.cycle += 4;
        },
        0x89 => {
            op0(tracer, state, "ADC  C");
            add_with_carry(cpu, cpu.c, cpu.flagY);
            state.cycle += 4;
        },
        0x8A => {
            op0(tracer, state, "ADC  D");
            add_with_carry(cpu, cpu.d, cpu.flagY);
            state.cycle += 4;
        },
        0x8B => {
            op0(tracer, state, "ADC  E");
            add_with_carry(cpu, cpu.e, cpu.flagY);
            state.cycle += 4;
        },
        0x8C => {
            op0(tracer, state, "ADC  H");
            add_with_carry(cpu, hi(cpu.hl), cpu.flagY);
            state.cycle += 4;
        },
        0x8D => {
            op0(tracer, state, "ADC  L");
            add_with_carry(cpu, lo(cpu.hl), cpu.flagY);
            state.cycle += 4;
        },
        0x8F => {
            op0(tracer, state, "ADC  A");
            add_with_carry(cpu, cpu.a, cpu.flagY);
            state.cycle += 4;
        },
        0x90 => {
            op0(tracer, state, "SUB  B");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.b, 0);
            state.cycle += 4;
        },
        0x91 => {
            op0(tracer, state, "SUB  C");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.c, 0);
            state.cycle += 4;
        },
        0x92 => {
            op0(tracer, state, "SUB  D");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.d, 0);
            state.cycle += 4;
        },
        0x93 => {
            op0(tracer, state, "SUB  E");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.e, 0);
            state.cycle += 4;
        },
        0x94 => {
            op0(tracer, state, "SUB  H");
            cpu.a = subtract_with_borrow(cpu, cpu.a, hi(cpu.hl), 0);
            state.cycle += 4;
        },
        0x95 => {
            op0(tracer, state, "SUB  L");
            cpu.a = subtract_with_borrow(cpu, cpu.a, lo(cpu.hl), 0);
            state.cycle += 4;
        },
        0x97 => {
            op0(tracer, state, "SUB  A");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.a, 0);
            state.cycle += 4;
        },
        0x98 => {
            op0(tracer, state, "SBC  B");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.b, cpu.flagY);
            state.cycle += 4;
        },
        0x99 => {
            op0(tracer, state, "SBC  C");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.c, cpu.flagY);
            state.cycle += 4;
        },
        0x9A => {
            op0(tracer, state, "SBC  D");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.d, cpu.flagY);
            state.cycle += 4;
        },
        0x9B => {
            op0(tracer, state, "SBC  E");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.e, cpu.flagY);
            state.cycle += 4;
        },
        0x9C => {
            op0(tracer, state, "SBC  H");
            cpu.a = subtract_with_borrow(cpu, cpu.a, hi(cpu.hl), cpu.flagY);
            state.cycle += 4;
        },
        0x9D => {
            op0(tracer, state, "SBC  L");
            cpu.a = subtract_with_borrow(cpu, cpu.a, lo(cpu.hl), cpu.flagY);
            state.cycle += 4;
        },
        0x9F => {
            op0(tracer, state, "SBC  A");
            cpu.a = subtract_with_borrow(cpu, cpu.a, cpu.a, cpu.flagY);
            state.cycle += 4;
        },
        0xA0 => {
            op0(tracer, state, "AND  B");
            const res = cpu.a & cpu.b;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA1 => {
            op0(tracer, state, "AND  C");
            const res = cpu.a & cpu.c;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA2 => {
            op0(tracer, state, "AND  D");
            const res = cpu.a & cpu.d;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA3 => {
            op0(tracer, state, "AND  E");
            const res = cpu.a & cpu.e;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA4 => {
            op0(tracer, state, "AND  H");
            const res = cpu.a & hi(cpu.hl);
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA5 => {
            op0(tracer, state, "AND  L");
            const res = cpu.a & lo(cpu.hl);
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA6 => {
            op0(tracer, state, "AND  (HL)");
            const res = cpu.a & state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xA7 => {
            op0(tracer, state, "AND  A");
            const res = cpu.a & cpu.a;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA8 => {
            op0(tracer, state, "XOR  B");
            const res = cpu.a ^ cpu.b;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA9 => {
            op0(tracer, state, "XOR  C");
            const res = cpu.a ^ cpu.c;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAA => {
            op0(tracer, state, "XOR  D");
            const res = cpu.a ^ cpu.d;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAB => {
            op0(tracer, state, "XOR  E");
            const res = cpu.a ^ cpu.e;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAC => {
            op0(tracer, state, "XOR  H");
            const res = cpu.a ^ hi(cpu.hl);
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAD => {
            op0(tracer, state, "XOR  L");
            const res = cpu.a ^ lo(cpu.hl);
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAF => {
            op0(tracer, state, "XOR  A");
            const res = cpu.a ^ cpu.a;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB0 => {
            op0(tracer, state, "OR   B");
            const res = cpu.a | cpu.b;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB1 => {
            op0(tracer, state, "OR   C");
            const res = cpu.a | cpu.c;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB2 => {
            op0(tracer, state, "OR   D");
            const res = cpu.a | cpu.d;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB3 => {
            op0(tracer, state, "OR   E");
            const res = cpu.a | cpu.e;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB4 => {
            op0(tracer, state, "OR   H");
            const res = cpu.a | hi(cpu.hl);
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB5 => {
            op0(tracer, state, "OR   L");
            const res = cpu.a | lo(cpu.hl);
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB6 => {
            op0(tracer, state, "OR   (HL)");
            const res = cpu.a | state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xB7 => {
            op0(tracer, state, "OR   A");
            const res = cpu.a | cpu.a;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB8 => {
            op0(tracer, state, "CP   B");
            _ = subtract_with_borrow(cpu, cpu.a, cpu.b, 0);
            state.cycle += 4;
        },
        0xB9 => {
            op0(tracer, state, "CP   C");
            _ = subtract_with_borrow(cpu, cpu.a, cpu.c, 0);
            state.cycle += 4;
        },
        0xBA => {
            op0(tracer, state, "CP   D");
            _ = subtract_with_borrow(cpu, cpu.a, cpu.d, 0);
            state.cycle += 4;
        },
        0xBB => {
            op0(tracer, state, "CP   E");
            _ = subtract_with_borrow(cpu, cpu.a, cpu.e, 0);
            state.cycle += 4;
        },
        0xBC => {
            op0(tracer, state, "CP   H");
            _ = subtract_with_borrow(cpu, cpu.a, hi(cpu.hl), 0);
            state.cycle += 4;
        },
        0xBE => {
            op0(tracer, state, "CP   (HL)");
            _ = subtract_with_borrow(cpu, cpu.a, state.mem[cpu.hl], 0);
            state.cycle += 7;
        },
        0xC0 => {
            op0(tracer, state, "RET  NZ");
            if (cpu.flagZ == 0) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xC1 => {
            op0(tracer, state, "POP  BC");
            cpu.c = popStack(state);
            cpu.b = popStack(state);
            state.cycle += 10;
        },
        0xC2 => {
            const word = op2(tracer, state, "JP   NZ,");
            if (cpu.flagZ == 0) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xC3 => {
            const word = op2(tracer, state, "JP   ");
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC4 => {
            const word = op2(tracer, state, "CALL NZ,");
            if (cpu.flagZ == 0) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xC5 => {
            op0(tracer, state, "PUSH BC");
            pushStack(state, cpu.b);
            pushStack(state, cpu.c);
            state.cycle += 11;
        },
        0xC6 => {
            const byte = op1(tracer, state, "ADD  ");
            add_with_carry(cpu, byte, 0);
            state.cycle += 7;
        },
        0xC8 => {
            op0(tracer, state, "RET  Z");
            if (cpu.flagZ == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xC9 => {
            op0(tracer, state, "RET");
            const b = popStack(state);
            const a = popStack(state);
            cpu.pc = hilo(a, b);
            state.cycle += 10;
        },
        0xCA => {
            const word = op2(tracer, state, "JP   Z,");
            if (cpu.flagZ == 1) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xCC => {
            const word = op2(tracer, state, "CALL Z,");
            if (cpu.flagZ == 1) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xCD => {
            const word = op2(tracer, state, "CALL ");
            pushStack(state, hi(cpu.pc)); // hi then lo
            pushStack(state, lo(cpu.pc));
            cpu.pc = word;
            state.cycle += 17;
        },
        0xCE => {
            const byte = op1(tracer, state, "ADC  ");
            add_with_carry(cpu, byte, cpu.flagY);
            state.cycle += 7;
        },
        0xCF => {
            op0(tracer, state, "RST  1");
            pushStack(state, hi(cpu.pc)); // hi then lo
            pushStack(state, lo(cpu.pc));
            cpu.pc = 0x08;
            state.cycle += 4;
        },
        0xD0 => {
            op0(tracer, state, "RET  NC");
            if (cpu.flagY == 0) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xD1 => {
            op0(tracer, state, "POP  DE");
            cpu.e = popStack(state);
            cpu.d = popStack(state);
            state.cycle += 10;
        },
        0xD2 => {
            const word = op2(tracer, state, "JP   NC,");
            if (cpu.flagY == 0) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xD3 => {
            const byte = op1(tracer, state, "OUT  ");
            doOut(state, byte, cpu.a);
            state.cycle += 10;
        },
        0xD4 => {
            const word = op2(tracer, state, "CALL NC,");
            if (cpu.flagY == 0) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xD5 => {
            op0(tracer, state, "PUSH DE");
            pushStack(state, cpu.d);
            pushStack(state, cpu.e);
            state.cycle += 11;
        },
        0xD6 => {
            const byte = op1(tracer, state, "SUB  ");
            cpu.a = subtract_with_borrow(cpu, cpu.a, byte, 0);
            state.cycle += 7;
        },
        0xD7 => {
            op0(tracer, state, "RST  2");
            pushStack(state, hi(cpu.pc)); // hi then lo
            pushStack(state, lo(cpu.pc));
            cpu.pc = 0x10;
            state.cycle += 4;
        },
        0xD8 => {
            op0(tracer, state, "RET  CY");
            if (cpu.flagY == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xDA => {
            const word = op2(tracer, state, "JP   CY,");
            if (cpu.flagY == 1) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xDB => {
            const byte = op1(tracer, state, "IN   ");
            cpu.a = doIn(state, byte);
            state.cycle += 10;
        },
        0xDC => {
            const word = op2(tracer, state, "CALL CY,");
            if (cpu.flagY == 1) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xDE => {
            const byte = op1(tracer, state, "SBC  ");
            cpu.a = subtract_with_borrow(cpu, cpu.a, byte, cpu.flagY);
            state.cycle += 7;
        },
        0xE0 => {
            op0(tracer, state, "RET  PO");
            if (cpu.flagP == 0) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xE1 => {
            op0(tracer, state, "POP  HL");
            const b = popStack(state);
            const a = popStack(state);
            cpu.hl = hilo(a, b);
            state.cycle += 10;
        },
        0xE2 => {
            const word = op2(tracer, state, "JP   PO,");
            if (cpu.flagP == 0) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xE3 => {
            op0(tracer, state, "EX   (SP),HL");
            const b = state.mem[state.cpu.sp];
            const a = state.mem[state.cpu.sp + 1];
            state.mem[state.cpu.sp] = lo(cpu.hl);
            state.mem[state.cpu.sp + 1] = hi(cpu.hl);
            cpu.hl = hilo(a, b);
            state.cycle += 18;
        },
        0xE4 => {
            const word = op2(tracer, state, "CALL PO,");
            if (cpu.flagP == 0) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xE5 => {
            op0(tracer, state, "PUSH HL");
            pushStack(state, hi(cpu.hl));
            pushStack(state, lo(cpu.hl));
            state.cycle += 11;
        },
        0xE6 => {
            const byte = op1(tracer, state, "AND  ");
            const res = cpu.a & byte;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xE8 => {
            op0(tracer, state, "RET  PE");
            if (cpu.flagP == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xE9 => {
            op0(tracer, state, "JP   (HL)");
            cpu.pc = cpu.hl;
            state.cycle += 5;
        },
        0xEA => {
            const word = op2(tracer, state, "JP   PE,");
            if (cpu.flagP == 1) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xEB => {
            op0(tracer, state, "EX   DE,HL");
            const de = cpu.DE();
            cpu.setDE(cpu.hl);
            cpu.hl = de;
            state.cycle += 4;
        },
        0xEC => {
            const word = op2(tracer, state, "CALL PE,");
            if (cpu.flagP == 1) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xEE => {
            const byte = op1(tracer, state, "XOR  ");
            const res = cpu.a ^ byte;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xF0 => {
            op0(tracer, state, "RET  P");
            if (cpu.flagS == 0) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xF1 => {
            op0(tracer, state, "POP  PSW");
            cpu.restoreFlags(popStack(state));
            cpu.a = popStack(state);
            state.cycle += 10;
        },
        0xF2 => {
            const word = op2(tracer, state, "JP   P,");
            if (cpu.flagS == 0) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xF4 => {
            const word = op2(tracer, state, "CALL P,");
            if (cpu.flagS == 0) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xF5 => {
            op0(tracer, state, "PUSH PSW");
            pushStack(state, cpu.a);
            pushStack(state, cpu.saveFlags());
            state.cycle += 11;
        },
        0xF6 => {
            const byte = op1(tracer, state, "OR   ");
            const res = cpu.a | byte;
            cpu.a = res;
            setFlags(cpu, res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xF8 => {
            op0(tracer, state, "RET  MI");
            if (cpu.flagS == 1) {
                const b = popStack(state);
                const a = popStack(state);
                cpu.pc = hilo(a, b);
                state.cycle += 11;
            } else {
                state.cycle += 5;
            }
        },
        0xFA => {
            const word = op2(tracer, state, "JP   MI,");
            if (cpu.flagS == 1) {
                cpu.pc = word;
            }
            state.cycle += 10;
        },
        0xFB => {
            op0(tracer, state, "EI");
            state.interrupts_enabled = true;
            state.cycle += 4;
        },
        0xFC => {
            const word = op2(tracer, state, "CALL MI,");
            if (cpu.flagS == 1) {
                pushStack(state, hi(cpu.pc)); // hi then lo
                pushStack(state, lo(cpu.pc));
                cpu.pc = word;
                state.cycle += 17;
            } else {
                state.cycle += 11;
            }
        },
        0xFE => {
            const byte = op1(tracer, state, "CP   ");
            _ = subtract_with_borrow(cpu, cpu.a, byte, 0);
            state.cycle += 7;
        },
        else => {
            tracer(state, "[0x{X:0>2}]", .{op});
            print("**unknown opcode: {X:0>2}", .{op});
            std.process.exit(0);
        },
    }
}

fn stop(state: *State, op: u8) void {
    print("**opcode: {X:0>2}\n{d:8}  STOP", .{ op, 1 + state.icount });
    std.process.exit(0);
}

fn op0(comptime tracer: Tracer, state: *State, comptime op: []const u8) void {
    tracer(state, op, .{});
}

fn op1(comptime tracer: Tracer, state: *State, comptime op: []const u8) u8 {
    return op1g(tracer, state, op ++ "{X:0>2}");
}

fn op1g(comptime tracer: Tracer, state: *State, comptime op: []const u8) u8 {
    const byte = fetch(state);
    tracer(state, op, .{byte});
    return byte;
}

fn op2(comptime tracer: Tracer, state: *State, comptime op: []const u8) u16 {
    return op2g(tracer, state, op ++ "{X:0>4}");
}

fn op2g(comptime tracer: Tracer, state: *State, comptime op: []const u8) u16 {
    const word = fetch16(state);
    tracer(state, op, .{word});
    return word;
}

pub const Cpu = struct {
    pc: u16,
    sp: u16,
    hl: u16,
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    flagS: u1,
    flagZ: u1,
    flagP: u1,
    flagY: u1,
    fn setBC(self: *Cpu, word: u16) void {
        self.b = hi(word);
        self.c = lo(word);
    }
    fn setDE(self: *Cpu, word: u16) void {
        self.d = hi(word);
        self.e = lo(word);
    }
    fn BC(self: *Cpu) u16 {
        return hilo(self.b, self.c);
    }
    fn DE(self: *Cpu) u16 {
        return hilo(self.d, self.e);
    }
    fn saveFlags(self: *Cpu) u8 {
        var res: u8 = 0;
        if (self.flagS == 1) res += 0x80;
        if (self.flagZ == 1) res += 0x40;
        if (self.flagP == 1) res += 0x04;
        if (self.flagY == 1) res += 0x01;
        return res;
    }
    fn restoreFlags(self: *Cpu, byte: u8) void {
        self.flagS = if (byte & 0x80 == 0) 0 else 1;
        self.flagZ = if (byte & 0x40 == 0) 0 else 1;
        self.flagP = if (byte & 0x04 == 0) 0 else 1;
        self.flagY = if (byte & 0x01 == 0) 0 else 1;
    }
    const init = Cpu{
        .pc = 0,
        .sp = 0,
        .a = 0,
        .hl = 0,
        .b = 0,
        .c = 0,
        .d = 0,
        .e = 0,
        .flagS = 0,
        .flagZ = 0,
        .flagP = 0,
        .flagY = 0,
    };
};

const Shifter = struct {
    lo: u8,
    hi: u8,
    offset: u3,
    const init = Shifter{ .lo = 0, .hi = 0, .offset = 0 };
};

fn hilo(a: u8, b: u8) u16 {
    switch (native_endian) {
        .big => return @bitCast([_]u8{ a, b }),
        .little => return @bitCast([_]u8{ b, a }),
    }
}

fn lo(word: u16) u8 {
    const byte_pair: [2]u8 = @bitCast(word);
    switch (native_endian) {
        .big => return byte_pair[1],
        .little => return byte_pair[0],
    }
}

fn hi(word: u16) u8 {
    const byte_pair: [2]u8 = @bitCast(word);
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

fn fetch16(state: *State) u16 {
    const b = fetch(state);
    const a = fetch(state);
    return hilo(a, b);
}

fn fetch(state: *State) u8 {
    const op = state.mem[state.cpu.pc];
    state.cpu.pc += 1;
    return op;
}

fn decrement(byte: u8) u8 {
    return byte -% 1;
}

fn increment(byte: u8) u8 {
    return byte +% 1;
}

fn setFlags(cpu: *Cpu, byte: u8) void {
    cpu.flagS = if (byte & 0x80 == 0) 0 else 1;
    cpu.flagP = parity(byte); //reduces speed-up approx x1700 to x1200
    cpu.flagZ = if (byte == 0) 1 else 0;
}

fn parity(byte: u8) u1 {
    var count: usize = 0;
    inline for (0..8) |i| {
        if (byte & @as(u8, 1) << i != 0) count += 1;
    }
    return if (count % 2 == 0) 1 else 0;
}

fn doOut(state: *State, channel: u8, value: u8) void {
    switch (channel) {
        1 => {}, //ignore output on port-1 for test0
        2 => state.shifter.offset = @truncate(value),
        3 => {}, //TODO sound
        4 => {
            // looks like generated C code in space-invaders repo has these assignments swapped. bug?
            state.shifter.lo = state.shifter.hi;
            state.shifter.hi = value;
        },
        5 => {}, //TODO sound
        6 => {}, //watchdog; ignore
        else => {
            print("**doOut: channel={X:0>2} value={X:0>2}\n", .{ channel, value });
            stop(state, 0xD3);
        },
    }
}

fn doIn(state: *State, channel: u8) u8 {
    const buttons = state.buttons;
    switch (channel) {
        1 => {
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
        2 => {
            return 0x00;
        },
        3 => {
            return (state.shifter.hi << state.shifter.offset) | ((state.shifter.lo >> (7 - state.shifter.offset)) >> 1);
        },
        else => {
            print("**doIn: channel={X:0>2}\n", .{channel});
            unreachable;
        },
    }
}

fn dad(cpu: *Cpu, word: u16) void { // double add
    const res: u17 = @as(u17, cpu.hl) + @as(u17, word);
    cpu.hl = @truncate(res);
    cpu.flagY = @truncate(res >> 16);
}

fn add_with_carry(cpu: *Cpu, byte: u8, cin: u1) void {
    const res: u9 = @as(u9, cpu.a) + @as(u9, byte) + cin;
    const res_byte: u8 = @truncate(res);
    cpu.a = res_byte;
    setFlags(cpu, res_byte);
    cpu.flagY = @truncate(res >> 8);
}

fn subtract_with_borrow(cpu: *Cpu, a: u8, b0: u8, borrow: u1) u8 {
    const b = b0 + borrow;
    if (b > a) {
        cpu.flagY = 1;
        const xres = 256 + @as(u9, a) - @as(u9, b);
        const res: u8 = @truncate(xres);
        setFlags(cpu, res);
        return res;
    }
    cpu.flagY = 0;
    const xres = @as(u9, a - b);
    const res: u8 = @truncate(xres);
    setFlags(cpu, res);
    return res;
}
