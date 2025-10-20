const std = @import("std");
const debug = std.debug;
const print = debug.print;
const billion = 1_000_000_000;
const wallclock = @import("wallclock");
const command_line = @import("command_line");
const machine = @import("machine");

pub fn main() !void {
    const mode = command_line.parse_mode();
    var mem = [_]u8{0} ** machine.mem_size;
    try load_roms(&mem);
    var state = machine.init_state(&mem);

    switch (mode) {
        .test0 => try test0(),
        .test1 => trace_emulate(test1_tracer, &state, 50_000),
        .test2 => trace_emulate(test2_tracer, &state, 10_000_000),

        .graphics => try graphics_main(&state),

        .speed => {
            const tic = wallclock.time();
            trace_emulate(null_tracer, &state, 5_000_000);
            const toc = wallclock.time();

            const nanos_per_clock_cycle = billion / machine.clock_frequency; //500
            const cycles = state.cycle;
            const wall_ns: u64 = toc - tic;
            const sim_s = @as(f32, @floatFromInt(cycles)) / machine.clock_frequency;
            const wall_s = @as(f32, @floatFromInt(wall_ns)) / billion;
            const speed = nanos_per_clock_cycle * cycles / wall_ns;
            print("sim(s) = {d:.3}; wall(s) = {d:.3}; speed-up factor: x{d}\n", .{
                sim_s,
                wall_s,
                speed,
            });
        },
    }
}

fn trace_emulate(tracer: machine.Tracer, state: *machine.State, max_steps: u64) void {
    while (state.icount <= max_steps) {
        machine.step(tracer, state);
    }
}

const rom_size = 2 * 1024;

fn load_roms(mem: []u8) !void {
    const dir = std.fs.cwd();
    _ = try dir.readFile("invaders.h", mem[0..]);
    _ = try dir.readFile("invaders.g", mem[rom_size..]);
    _ = try dir.readFile("invaders.f", mem[2 * rom_size ..]);
    _ = try dir.readFile("invaders.e", mem[3 * rom_size ..]);
}

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});
const mix = @cImport({
    @cInclude("SDL2/SDL_mixer.h");
});

const render_scale = 3;

const pixel_w = 224;
const pixel_h = 256;

fn draw_screen(renderer: *c.SDL_Renderer, state: *machine.State) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 40, 40, 40, 255);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    var counter: usize = 0x2400;
    for (0..pixel_w) |y| {
        for (0..pixel_h / 8) |xi| {
            const byte = state.mem[counter];
            counter += 1;
            for (0..8) |i| {
                const x = xi * 8 + i;
                const on = ((byte >> @intCast(i)) & 1) == 1;
                if (on) {
                    const rect = c.SDL_Rect{
                        .x = @intCast(y * render_scale),
                        .y = @intCast((255 - x) * render_scale),
                        .w = render_scale,
                        .h = render_scale,
                    };
                    _ = c.SDL_RenderFillRect(renderer, &rect);
                }
            }
        }
    }
}

fn graphics_main(state: *machine.State) !void {
    if (c.SDL_Init(c.SDL_INIT_EVERYTHING) != 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const screen_w = render_scale * pixel_w;
    const screen_h = render_scale * pixel_h;

    const screen = c.SDL_CreateWindow("Space Invaders", 500, //c.SDL_WINDOWPOS_UNDEFINED,
        50, //c.SDL_WINDOWPOS_UNDEFINED,
        screen_w, screen_h, c.SDL_WINDOW_OPENGL) orelse {
        c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(screen);

    const renderer = c.SDL_CreateRenderer(screen, -1, 0) orelse {
        c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const sounds = init_sounds();

    print("starting event loop\n", .{});
    var quit = false;
    var frame: usize = 0;
    const tic = wallclock.time();
    var max_cycles: u64 = 0;
    var speed_up_factor: i32 = 1;

    while (!quit) {
        //print("{d} P3={X:0>2} P5={X:0>2}\n",.{frame, state.port3, state.port5});
        //var buf: [32]u8 = undefined;
        //_ = try std.fmt.bufPrint(&buf, "frame {d} @ x{d}\x00", .{ frame, speed_up_factor });
        //c.SDL_SetWindowTitle(screen, &buf);
        draw_screen(renderer, state);
        c.SDL_RenderPresent(renderer);
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            //print("{any}\n",.{event});
            process_event(event, &state.buttons, &quit);
        }
        const cycles_per_display_frame = if (speed_up_factor < 0) 0 else 2 * machine.half_frame_cycles * @as(u32, @intCast(speed_up_factor));
        frame += 1;
        max_cycles += cycles_per_display_frame;

        const last_port3: u8 = state.port3;
        const last_port5: u8 = state.port5;

        while (state.cycle <= max_cycles) {
            machine.step(null_tracer, state);
        }

        if (state.port3 != last_port3) {
            if (last_port3 & 1 == 0 and state.port3 & 1 != 0) play(sounds.ufo);
            if (last_port3 & 2 == 0 and state.port3 & 2 != 0) play(sounds.shot);
            if (last_port3 & 4 == 0 and state.port3 & 4 != 0) play(sounds.player_die);
            if (last_port3 & 8 == 0 and state.port3 & 8 != 0) play(sounds.invader_die);
            if (last_port3 & 16 == 0 and state.port3 & 16 != 0) play(sounds.extra_life);
        }
        if (state.port5 != last_port5) {
            if (last_port5 & 1 == 0 and state.port5 & 1 != 0) play(sounds.fleet1);
            if (last_port5 & 2 == 0 and state.port5 & 2 != 0) play(sounds.fleet2);
            if (last_port5 & 4 == 0 and state.port5 & 4 != 0) play(sounds.fleet3);
            if (last_port5 & 8 == 0 and state.port5 & 8 != 0) play(sounds.fleet4);
            if (last_port5 & 16 == 0 and state.port5 & 16 != 0) play(sounds.ufo_hit);
        }

        const toc = wallclock.time();
        const wall_ns: u64 = toc - tic;
        const wall_s = @as(f32, @floatFromInt(wall_ns)) / billion;
        const desired_display_fps = 60;
        const desired_s: f32 =
            @as(f32, @floatFromInt(frame)) / @as(f32, @floatFromInt(desired_display_fps));
        const pause_ms: i32 = @intFromFloat((desired_s - wall_s) * 1000);
        //print("{d} ",.{pause_ms});
        if (pause_ms > 0) {
            c.SDL_Delay(@intCast(pause_ms));
        }
        if (false) speed_up_factor = speed_up_factor + pause_ms;
    }
    print("event loop ended\n", .{});
}

fn process_event(event: c.SDL_Event, buttons: *machine.Buttons, quit: *bool) void {
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

fn process_sym(sym: i32, buttons: *machine.Buttons, pressed: bool) void {
    if (sym == c.SDLK_INSERT) buttons.coin_deposit = pressed;
    if (sym == c.SDLK_F1) buttons.one_player_start = pressed;
    if (sym == c.SDLK_F2) buttons.two_player_start = pressed;
    if (sym == c.SDLK_RETURN) buttons.p1_fire = pressed;
    if (sym == 'z') buttons.p1_left = pressed;
    if (sym == 'x') buttons.p1_right = pressed;
}

const Chunk = [*c]mix.Mix_Chunk;

fn play(sound: Chunk) void {
    _ = mix.Mix_PlayChannel(-1, sound, 0);
}

const Sounds = struct {
    ufo: Chunk,
    shot: Chunk,
    invader_die: Chunk,
    player_die: Chunk,
    extra_life: Chunk,
    fleet1: Chunk,
    fleet2: Chunk,
    fleet3: Chunk,
    fleet4: Chunk,
    ufo_hit: Chunk,
};

fn init_sounds() Sounds {
    //print("loading sounds\n", .{});
    const frequency = 44100;
    const format = mix.AUDIO_U16LSB;
    const channels = 1;
    const chunksize = 1024;
    _ = mix.Mix_OpenAudio(frequency, format, channels, chunksize);
    return Sounds{
        .ufo = load_sound("sounds/Ufo.wav"),
        .shot = load_sound("sounds/Shot.wav"),
        .invader_die = load_sound("sounds/InvaderDie.wav"),
        .player_die = load_sound("sounds/PlayerDie.wav"),
        .extra_life = load_sound("sounds/ExtraLife.wav"),
        .fleet1 = load_sound("sounds/FleetMovement1.wav"),
        .fleet2 = load_sound("sounds/FleetMovement2.wav"),
        .fleet3 = load_sound("sounds/FleetMovement3.wav"),
        .fleet4 = load_sound("sounds/FleetMovement4.wav"),
        .ufo_hit = load_sound("sounds/UfoHit.wav"),
    };
}

fn load_sound(filename: [*c]const u8) Chunk {
    const chunk = mix.Mix_LoadWAV(filename);
    if (chunk != 0) {
        return chunk;
    }
    print("failed to load sound file: {s}\n", .{filename});
    unreachable; // TODO: use idomatic zig errors
}

fn null_tracer(state: *machine.State, comptime fmt: []const u8, args: anytype) void {
    _ = state;
    _ = fmt;
    _ = args;
}

pub const Config = struct {
    trace_from: u64,
    trace_every: u64,
    trace_pixs: bool,
};

fn test1_tracer(state: *machine.State, comptime fmt: []const u8, args: anytype) void {
    const config = Config{
        .trace_from = 0,
        .trace_every = 1,
        .trace_pixs = false,
    };
    config_tracer(config, state, fmt, args);
}

fn test2_tracer(state: *machine.State, comptime fmt: []const u8, args: anytype) void {
    const config = Config{
        .trace_from = 0,
        .trace_every = 10_000,
        .trace_pixs = true,
    };
    config_tracer(config, state, fmt, args);
}

fn config_tracer(config: Config, state: *machine.State, comptime fmt: []const u8, args: anytype) void {
    if (state.icount >= config.trace_from and state.icount % config.trace_every == 0) {
        printTraceLine(state);
        print(fmt, args);
        if (config.trace_pixs) {
            print(" #pixs:{d}\n", .{count_on_pixels(state.mem)});
        } else {
            print("\n", .{});
        }
    }
}

fn printTraceLine(state: *machine.State) void {
    const cpu = state.cpu;
    print("{d:8}  [{d:0>8}] PC:{X:0>4} A:{X:0>2} B:{X:0>2} C:{X:0>2} D:{X:0>2} E:{X:0>2} HL:{X:0>4} SP:{X:0>4} SZAPY:{x}{x}?{x}{x} : ", .{
        state.icount,
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
        cpu.flagP,
        cpu.flagY,
    });
}

fn count_on_pixels(mem: []u8) u64 {
    var res: u64 = 0;
    for (0x2400..0x4000) |i| { //video ram
        res += count_bits(mem[i]);
    }
    return res;
}

fn count_bits(byte: u8) u8 {
    //TODO: comptime inline loop
    var res: u8 = 0;
    res += (if (byte & (1 << 0) == 0) 0 else 1);
    res += (if (byte & (1 << 1) == 0) 0 else 1);
    res += (if (byte & (1 << 2) == 0) 0 else 1);
    res += (if (byte & (1 << 3) == 0) 0 else 1);
    res += (if (byte & (1 << 4) == 0) 0 else 1);
    res += (if (byte & (1 << 5) == 0) 0 else 1);
    res += (if (byte & (1 << 6) == 0) 0 else 1);
    res += (if (byte & (1 << 7) == 0) 0 else 1);
    return res;
}

fn test0() !void {
    var mem = [_]u8{0} ** machine.mem_size;
    _ = try std.fs.cwd().readFile("TST8080.COM", mem[0x100..]);
    var state = machine.init_state(&mem);
    state.cpu.pc = 0x100;
    //mem[0] = 0xD3;
    mem[5] = 0xD3;
    mem[6] = 0x01;
    mem[7] = 0xC9;
    const max_steps = 519; //DAA at 520. DAA at 525 goes wrong
    trace_emulate(test0_tracer, &state, max_steps);
}

fn test0_tracer(state: *machine.State, comptime fmt: []const u8, args: anytype) void {
    printTraceLine0(state);
    print(fmt, args);
    print("\n", .{});
}

fn printTraceLine0(state: *machine.State) void {
    const cpu = state.cpu;
    print("PC:{X:0>4} A:{X:0>2} B:{X:0>2} C:{X:0>2} D:{X:0>2} E:{X:0>2} HL:{X:0>4} SP:{X:0>4} SZAPY:{x}{x}{x}{x}{x} {d:>7}  [{d:0>8}] {X:0>4} : ", .{
        cpu.pc,
        cpu.a,
        //flags_byte(cpu),
        cpu.b,
        cpu.c,
        cpu.d,
        cpu.e,
        cpu.hl,
        cpu.sp,
        cpu.flagS,
        cpu.flagZ,
        cpu.flagA,
        cpu.flagP,
        cpu.flagY,
        state.icount,
        state.cycle,
        cpu.pc,
    });
}
