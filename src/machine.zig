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
    p1_left : bool,
    p1_right : bool,
    p1_fire : bool,

    pub const init = Buttons {
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
    icount : u64, //count of instructions executed
    cycle : u64, //count of simulated cycles (at clock speed of 2 MhZ)
    mem : []u8,
    cpu : Cpu,
    shifter: Shifter,
    interrupts_enabled : bool,
    next_wakeup : u64,
    next_interrupt_op : u8,
};

pub fn init_state(mem: []u8) State {
    const state : State = State {
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

fn step_op(comptime tracer: Tracer, state : *State, op:u8) void {
    switch (op) {
        inline else => |ct_op| {
            step_ct_op(tracer, state, ct_op);
        }
    }
}

fn step_ct_op(comptime tracer: Tracer, state : *State, comptime op:u8) void {
    const cpu = &state.cpu;
    switch (op) {
        0x00 => {
            tracer(state, "NOP",.{});
            state.cycle += 4;
        },
        0x01 => {
            const word = fetch16(state);
            tracer(state, "LD   BC,{X:0>4}", .{word});
            cpu.setBC(word);
            state.cycle += 10;
        },
        0x03 => {
            tracer(state, "INC  BC", .{});
            cpu.setBC(1 + cpu.BC());
            state.cycle += 5;
        },
        0x04 => {
            tracer(state, "INC  B", .{});
            const byte = increment(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x05 => {
            tracer(state, "DEC  B", .{});
            const byte = decrement(cpu.b);
            cpu.b = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x06 => {
            const byte = fetch(state);
            tracer(state, "LD   B,{X:0>2}", .{byte});
            cpu.b = byte;
            state.cycle += 7;
        },
        0x07 => {
            tracer(state, "RLCA", .{});
            const shunted : u1 = @truncate(cpu.a >> 7);
            cpu.a = cpu.a<<1 | shunted;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x09 => {
            tracer(state, "ADD  HL,BC", .{});
            dad(cpu,cpu.BC());
            state.cycle += 10;
        },
        0x0A => {
            tracer(state, "LD   A,(BC)", .{});
            cpu.a = state.mem[cpu.BC()];
            state.cycle += 7;
        },
        0x0C => {
            tracer(state, "INC  C", .{});
            const byte = increment(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x0D => {
            tracer(state, "DEC  C", .{});
            const byte = decrement(cpu.c);
            cpu.c = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x0E => {
            const byte = fetch(state);
            tracer(state, "LD   C,{X:0>2}", .{byte});
            cpu.c = byte;
            state.cycle += 7;
        },
        0x0F => {
            tracer(state, "RRCA", .{});
            const shunted : u1 = @truncate(cpu.a);
            cpu.a = @as(u8,shunted)<<7 | cpu.a>>1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x11 => {
            const word = fetch16(state);
            tracer(state, "LD   DE,{X:0>4}", .{word});
            cpu.setDE(word);
            state.cycle += 10;
        },
        0x12 => {
            tracer(state, "LD   (DE),A", .{});
            var addr = cpu.DE();
            if (addr >= mem_size) addr -= 0x2000; //ram mirror
            state.mem[addr] = cpu.a;
            state.cycle += 7;
        },
        0x13 => {
            tracer(state, "INC  DE", .{});
            cpu.setDE(1 + cpu.DE());
            state.cycle += 5;
        },
        0x14 => {
            tracer(state, "INC  D", .{});
            const byte = increment(cpu.d);
            cpu.d = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x15 => {
            tracer(state, "DEC  D", .{});
            const byte = decrement(cpu.d);
            cpu.d = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x16 => {
            const byte = fetch(state);
            tracer(state, "LD   D,{X:0>2}", .{byte});
            cpu.d = byte;
            state.cycle += 7;
        },
        0x19 => {
            tracer(state, "ADD  HL,DE", .{});
            dad(cpu,cpu.DE());
            state.cycle += 10;
        },
        0x1A => {
            tracer(state, "LD   A,(DE)", .{});
            cpu.a = state.mem[cpu.DE()];
            state.cycle += 7;
        },
        0x1B => {
            tracer(state, "DEC  DE", .{});
            cpu.setDE(if (cpu.DE() == 0) 0xffff else cpu.DE() - 1);
            state.cycle += 5;
        },
        0x1F => {
            tracer(state, "RAR", .{});
            const shunted : u1 = @truncate(cpu.a);
            cpu.a = @as(u8,cpu.flagY)<<7 | cpu.a>>1;
            cpu.flagY = shunted;
            state.cycle += 4;
        },
        0x21 => {
            const word = fetch16(state);
            tracer(state, "LD   HL,{X:0>4}", .{word});
            cpu.hl = word;
            state.cycle += 10;
        },
        0x22 => {
            var word = fetch16(state);
            tracer(state, "LD   ({X:0>4}),HL", .{word});
            if (word >= mem_size) {
                //word -= 0x2000; //ram mirror
                const masked = word & 0x3fff;
                print("OOB: {X:0>4} --> {X:0>4}\n",.{word,masked});
                word = masked;
            }
            state.mem[word] = lo(cpu.hl);
            state.mem[word+1] = hi(cpu.hl);
            state.cycle += 16;
        },
        0x23 => {
            tracer(state, "INC  HL", .{});
            cpu.hl += 1;
            state.cycle += 5;
        },
        0x26 => {
            const byte = fetch(state);
            tracer(state, "LD   H,{X:0>2}", .{byte});
            cpu.hl = hilo(byte,lo(cpu.hl));
            state.cycle += 7;
        },
        0x27 => {
            tracer(state, "DAA", .{});
            print("DAA\n",.{});
            //TODO
            state.cycle += 4;
        },
        0x29 => {
            tracer(state, "ADD  HL,HL", .{});
            dad(cpu,cpu.hl);
            state.cycle += 10;
        },
        0x2A => {
            const word = fetch16(state);
            tracer(state, "LD   HL,({X:0>4})", .{word});
            cpu.hl = hilo (state.mem[word+1], state.mem[word]);
            state.cycle += 16;
        },
        0x2B => {
            tracer(state, "DEC  HL", .{});
            cpu.hl = if (cpu.hl == 0) 0xffff else cpu.hl - 1;
            state.cycle += 5;
        },
        0x2C => {
            tracer(state, "INC  L", .{});
            const byte = increment(lo(cpu.hl));
            cpu.hl = hilo(hi(cpu.hl),byte);
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x2E => {
            const byte = fetch(state);
            tracer(state, "LD   L,{X:0>2}", .{byte});
            cpu.hl = hilo(hi(cpu.hl),byte);
            state.cycle += 7;
        },
        0x2F => {
            tracer(state, "CPL", .{});
            cpu.a = ~ cpu.a;
            state.cycle += 4;
        },
        0x31 => {
            const word = fetch16(state);
            tracer(state, "LD   SP,{X:0>4}", .{word});
            cpu.sp = word;
            state.cycle += 10;
        },
        0x32 => {
            const word = fetch16(state);
            tracer(state, "LD   ({X:0>4}),A", .{word});
            state.mem[word] = cpu.a;
            state.cycle += 13;
        },
        0x34 => {
            tracer(state, "INC  (HL)", .{});
            const byte = increment(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu,byte);
            state.cycle += 10;
        },
        0x35 => {
            tracer(state, "DEC  (HL)", .{});
            const byte = decrement(state.mem[cpu.hl]);
            state.mem[cpu.hl] = byte;
            setFlags(cpu,byte);
            state.cycle += 10;
        },
        0x36 => {
            const byte = fetch(state);
            tracer(state, "LD   (HL),{X:0>2}", .{byte});
            state.mem[cpu.hl] = byte;
            state.cycle += 10;
        },
        0x37 => {
            tracer(state, "SCF", .{});
            cpu.flagY = 1;
            state.cycle += 4;
        },
        0x3A => {
            const word = fetch16(state);
            tracer(state, "LD   A,({X:0>4})", .{word});
            cpu.a = state.mem[word];
            state.cycle += 13;
        },
        0x3C => {
            tracer(state, "INC  A", .{});
            const byte = increment(cpu.a);
            cpu.a = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x3D => {
            tracer(state, "DEC  A", .{});
            const byte = decrement(cpu.a);
            cpu.a = byte;
            setFlags(cpu,byte);
            state.cycle += 5;
        },
        0x3E => {
            const byte = fetch(state);
            tracer(state, "LD   A,{X:0>2}", .{byte});
            cpu.a = byte;
            state.cycle += 7;
        },
        0x41 => {
            tracer(state, "LD   B,C", .{});
            cpu.b = cpu.c;
            state.cycle += 5;
        },
        0x46 => {
            tracer(state, "LD   B,(HL)", .{});
            cpu.b = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x47 => {
            tracer(state, "LD   B,A", .{});
            cpu.b = cpu.a;
            state.cycle += 5;
        },
        0x48 => {
            tracer(state, "LD   C,B", .{});
            cpu.c = cpu.b;
            state.cycle += 5;
        },
        0x4E => {
            tracer(state, "LD   C,(HL)", .{});
            cpu.c = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x4F => {
            tracer(state, "LD   C,A", .{});
            cpu.c = cpu.a;
            state.cycle += 5;
        },
        0x56 => {
            tracer(state, "LD   D,(HL)", .{});
            cpu.d = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x57 => {
            tracer(state, "LD   D,A", .{});
            cpu.d = cpu.a;
            state.cycle += 5;
        },
        0x5E => {
            tracer(state, "LD   E,(HL)", .{});
            cpu.e = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x5F => {
            tracer(state, "LD   E,A", .{});
            cpu.e = cpu.a;
            state.cycle += 5;
        },
        0x61 => {
            tracer(state, "LD   H,C", .{});
            cpu.hl = hilo(cpu.c,lo(cpu.hl));
            state.cycle += 5;
        },
        0x65 => {
            tracer(state, "LD   H,L", .{});
            cpu.hl = hilo(lo(cpu.hl),lo(cpu.hl));
            state.cycle += 5;
        },
        0x66 => {
            tracer(state, "LD   H,(HL)", .{});
            cpu.hl = hilo(state.mem[cpu.hl],lo(cpu.hl));
            state.cycle += 7;
        },
        0x67 => {
            tracer(state, "LD   H,A", .{});
            cpu.hl = hilo(cpu.a,lo(cpu.hl));
            state.cycle += 5;
        },
        0x68 => {
            tracer(state, "LD   L,B", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.b);
            state.cycle += 5;
        },
        0x69 => {
            tracer(state, "LD   L,C", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.c);
            state.cycle += 5;
        },
        0x6F => {
            tracer(state, "LD   L,A", .{});
            cpu.hl = hilo(hi(cpu.hl),cpu.a);
            state.cycle += 5;
        },
        0x70 => {
            tracer(state, "LD   (HL),B", .{});
            state.mem[cpu.hl] = cpu.b;
            state.cycle += 7;
        },
        0x71 => {
            tracer(state, "LD   (HL),C", .{});
            state.mem[cpu.hl] = cpu.c;
            state.cycle += 7;
        },
        0x77 => {
            tracer(state, "LD   (HL),A", .{});
            var addr = cpu.hl;
            if (addr >= mem_size) addr -= 0x2000; //ram mirror
            state.mem[addr] = cpu.a;
            state.cycle += 7;
        },
        0x78 => {
            tracer(state, "LD   A,B", .{});
            cpu.a = cpu.b;
            state.cycle += 5;
        },
        0x79 => {
            tracer(state, "LD   A,C", .{});
            cpu.a = cpu.c;
            state.cycle += 5;
        },
        0x7A => {
            tracer(state, "LD   A,D", .{});
            cpu.a = cpu.d;
            state.cycle += 5;
        },
        0x7B => {
            tracer(state, "LD   A,E", .{});
            cpu.a = cpu.e;
            state.cycle += 5;
        },
        0x7C => {
            tracer(state, "LD   A,H", .{});
            cpu.a = hi(cpu.hl);
            state.cycle += 5;
        },
        0x7D => {
            tracer(state, "LD   A,L", .{});
            cpu.a = lo(cpu.hl);
            state.cycle += 5;
        },
        0x7E => {
            tracer(state, "LD   A,(HL)", .{});
            cpu.a = state.mem[cpu.hl];
            state.cycle += 7;
        },
        0x80 => {
            tracer(state, "ADD  B", .{});
            add_with_carry(cpu, cpu.b, 0);
            state.cycle += 4;
        },
        0x81 => {
            tracer(state, "ADD  C", .{});
            add_with_carry(cpu, cpu.c, 0);
            state.cycle += 4;
        },
        0x83 => {
            tracer(state, "ADD  E", .{});
            add_with_carry(cpu, cpu.e, 0);
            state.cycle += 4;
        },
        0x85 => {
            tracer(state, "ADD  L", .{});
            add_with_carry(cpu, lo(cpu.hl), 0);
            state.cycle += 4;
        },
        0x86 => {
            tracer(state, "ADD  (HL)", .{});
            add_with_carry(cpu, state.mem[cpu.hl], 0);
            state.cycle += 7;
        },
        0x8A => {
            tracer(state, "ADC  D", .{});
            add_with_carry(cpu, cpu.d, cpu.flagY);
            state.cycle += 4;
        },
        0x97 => {
            tracer(state, "SUB  A", .{});
            cpu.a = subtract_with_borrow(cpu,cpu.a,cpu.a,0);
            state.cycle += 4;
        },
        0xA0 => {
            tracer(state, "AND  B", .{});
            const res = cpu.a & cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA6 => {
            tracer(state, "AND  (HL)", .{});
            const res = cpu.a & state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xA7 => {
            tracer(state, "AND  A", .{});
            const res = cpu.a & cpu.a;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xA8 => {
            tracer(state, "XOR  B", .{});
            const res = cpu.a ^ cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xAF => {
            tracer(state, "XOR  A", .{});
            const res = cpu.a ^ cpu.a;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB0 => {
            tracer(state, "OR   B", .{});
            const res = cpu.a | cpu.b;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB4 => {
            tracer(state, "OR   H", .{});
            const res = cpu.a | hi(cpu.hl);
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 4;
        },
        0xB6 => {
            tracer(state, "OR   (HL)", .{});
            const res = cpu.a | state.mem[cpu.hl];
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xB8 => {
            tracer(state, "CP   B", .{});
            _ = subtract_with_borrow(cpu,cpu.a,cpu.b,0);
            state.cycle += 4;
        },
        0xBC => {
            tracer(state, "CP   H", .{});
            _ = subtract_with_borrow(cpu,cpu.a,hi(cpu.hl),0);
            state.cycle += 4;
        },
        0xBE => {
            tracer(state, "CP   (HL)", .{});
            _ = subtract_with_borrow(cpu,cpu.a,state.mem[cpu.hl],0);
            state.cycle += 7;
        },
        0xC0 => {
            tracer(state, "RET  NZ", .{});
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
            tracer(state, "POP  BC", .{});
            cpu.c = popStack(state);
            cpu.b = popStack(state);
            state.cycle += 10;
        },
        0xC2 => {
            const word = fetch16(state);
            tracer(state, "JP   NZ,{X:0>4}", .{word});
            if (cpu.flagZ == 0) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xC3 => {
            const word = fetch16(state);
            tracer(state, "JP   {X:0>4}", .{word});
            cpu.pc = word;
            state.cycle += 10;
        },
        0xC4 => {
            const word = fetch16(state);
            tracer(state, "CALL NZ,{X:0>4}", .{word});
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
            tracer(state, "PUSH BC", .{});
            pushStack(state,cpu.b);
            pushStack(state,cpu.c);
            state.cycle += 11;
        },
        0xC6 => {
            const byte = fetch(state);
            tracer(state, "ADD  {X:0>2}", .{byte});
            add_with_carry(cpu, byte, 0);
            state.cycle += 7;
        },
        0xC8 => {
            tracer(state, "RET  Z", .{});
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
            tracer(state, "RET", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.pc = hilo(a,b);
            state.cycle += 10;
        },
        0xCA => {
            const word = fetch16(state);
            tracer(state, "JP   Z,{X:0>4}", .{word});
            if (cpu.flagZ == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xCC => {
            const word = fetch16(state);
            tracer(state, "CALL Z,{X:0>4}", .{word});
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
            tracer(state, "CALL {X:0>4}", .{word});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = word;
            state.cycle += 17;
        },
        0xCF => {
            tracer(state, "RST  1", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x08;
            state.cycle += 4;
        },
        0xD0 => {
            tracer(state, "RET  NC", .{});
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
            tracer(state, "POP  DE", .{});
            cpu.e = popStack(state);
            cpu.d = popStack(state);
            state.cycle += 10;
        },
        0xD2 => {
            const word = fetch16(state);
            tracer(state, "JP   NC,{X:0>4}", .{word});
            if (cpu.flagY == 0) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xD3 => {
            const byte = fetch(state);
            tracer(state, "OUT  {X:0>2}", .{byte});
            doOut(state,byte,cpu.a);
            state.cycle += 10;
        },
        0xD4 => {
            const word = fetch16(state);
            tracer(state, "CALL NC,{X:0>4}", .{word});
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
            tracer(state, "PUSH DE", .{});
            pushStack(state,cpu.d);
            pushStack(state,cpu.e);
            state.cycle += 11;
        },
        0xD6 => {
            const byte = fetch(state);
            tracer(state, "SUB  {X:0>2}", .{byte});
            cpu.a = subtract_with_borrow(cpu,cpu.a,byte,0);
            state.cycle += 7;
        },
        0xD7 => {
            tracer(state, "RST  2", .{});
            pushStack(state,hi(cpu.pc)); // hi then lo
            pushStack(state,lo(cpu.pc));
            cpu.pc = 0x10;
            state.cycle += 4;
        },
        0xD8 => {
            tracer(state, "RET  CY", .{});
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
            tracer(state, "JP   CY,{X:0>4}", .{word});
            if (cpu.flagY == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xDB => {
            const byte = fetch(state);
            tracer(state, "IN   {X:0>2}", .{byte});
            cpu.a = doIn(state,byte);
            state.cycle += 10;
        },
        0xDE => {
            const byte = fetch(state);
            tracer(state, "SBC  {X:0>2}", .{byte});
            cpu.a = subtract_with_borrow(cpu,cpu.a,byte,cpu.flagY);
            state.cycle += 7;
        },
        0xE1 => {
            tracer(state, "POP  HL", .{});
            const b = popStack(state);
            const a = popStack(state);
            cpu.hl = hilo(a,b);
            state.cycle += 10;
        },
        0xE3 => {
            tracer(state, "EX   (SP),HL", .{});
            const b = state.mem[state.cpu.sp];
            const a = state.mem[state.cpu.sp+1];
            state.mem[state.cpu.sp] = lo(cpu.hl);
            state.mem[state.cpu.sp+1] = hi(cpu.hl);
            cpu.hl = hilo(a,b);
            state.cycle += 18;
        },
        0xE5 => {
            tracer(state, "PUSH HL", .{});
            pushStack(state,hi(cpu.hl));
            pushStack(state,lo(cpu.hl));
            state.cycle += 11;
        },
        0xE6 => {
            const byte = fetch(state);
            tracer(state, "AND  {X:0>2}", .{byte});
            const res = cpu.a & byte;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xE9 => {
            tracer(state, "JP   (HL)", .{});
            cpu.pc = cpu.hl;
            state.cycle += 5;
        },
        0xEB => {
            tracer(state, "EX   DE,HL", .{});
            const de = cpu.DE();
            cpu.setDE(cpu.hl);
            cpu.hl = de;
            state.cycle += 4;
        },
        0xF1 => {
            tracer(state, "POP  PSW", .{});
            cpu.restoreFlags(popStack(state));
            cpu.a = popStack(state);
            state.cycle += 10;
        },
        0xF5 => {
            tracer(state, "PUSH PSW", .{});
            pushStack(state,cpu.a);
            pushStack(state,cpu.saveFlags());
            state.cycle += 11;
        },
        0xF6 => {
            const byte = fetch(state);
            tracer(state, "OR   {X:0>2}", .{byte});
            const res = cpu.a | byte;
            cpu.a = res;
            setFlags(cpu,res);
            cpu.flagY = 0;
            state.cycle += 7;
        },
        0xFA => {
            const word = fetch16(state);
            tracer(state, "JP   MI,{X:0>4}", .{word});
            if (cpu.flagS == 1) { cpu.pc = word; }
            state.cycle += 10;
        },
        0xFB => {
            tracer(state, "EI", .{});
            state.interrupts_enabled = true;
            state.cycle += 4;
        },
        0xFE => {
            const byte = fetch(state);
            tracer(state, "CP   {X:0>2}", .{byte});
            _ = subtract_with_borrow(cpu,cpu.a,byte,0);
            state.cycle += 7;
        },
        else => {
            stop(state,op);
        }
    }
}

fn stop(state: *State, op: u8) void {
    print("**opcode: {X:0>2}\n{d:8}  STOP", .{op,1 + state.icount});
    std.process.exit(0);
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
