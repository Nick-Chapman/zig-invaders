const std = @import("std");
const debug = std.debug;
const print = debug.print;
const billion = 1_000_000_000;
const wallclock = @import("wallclock");
const command_line = @import("command_line");
const machine = @import("machine");

pub fn main() !void {
    const mode = command_line.parse_mode();
    const config = configure(mode);
    //print("** Zig Invaders ** {any}\n",.{config});
    var mem = [_]u8{0} ** machine.mem_size;
    try load_roms(&mem);
    var state = machine.init_state(config,&mem);
    if (mode == .graphics) {
        try graphics_main(&state);
        return;
    }
    const tic = wallclock.time();
    const enable_trace = ! (mode == .speed);

    switch (enable_trace) {
        inline else => |enable_trace_ct| {
            while (state.icount <= state.config.max_steps) {
                machine.step(enable_trace_ct, &state);
            }
        }
    }

    const toc = wallclock.time();
    const nanos_per_clock_cycle = billion / machine.clock_frequency; //500
    if (mode == .speed) {
        const cycles = state.cycle;
        const wall_ns : u64 = toc - tic;
        const sim_s = @as(f32,@floatFromInt(cycles)) / machine.clock_frequency;
        const wall_s = @as(f32,@floatFromInt(wall_ns)) / billion;
        const speed = nanos_per_clock_cycle * cycles / wall_ns;
        print("sim(s) = {d:.3}; wall(s) = {d:.3}; speed-up factor: x{d}\n" ,.{
            sim_s,
            wall_s,
            speed,
        });
    }
}

fn configure(mode: command_line.Mode) machine.Config {
    return switch (mode) {
        .test1 => .{
            .max_steps = 50_000,
            .trace_from = 0,
            .trace_every = 1,
            .trace_pixs = false,
        },
        .test2 => .{
            .max_steps = 10_000_000,
            .trace_from = 0,
            .trace_every = 10_000,
            .trace_pixs = true,
        },
        .dev => .{
            .max_steps = 10_000_000,
            .trace_from = 0,
            .trace_every = 1_000_000,
            .trace_pixs = true,
        },
        .speed => .{
            .max_steps = 2_000_000, // was 200mil for ReleaseFast
            .trace_from = 1,
            .trace_every = 1_000_000,
            .trace_pixs = false
        },
        .graphics => .{
            .max_steps = 0,
            .trace_from = 0,
            .trace_every = 100_000,
            .trace_pixs = false
        },
    };
}

const rom_size = 2 * 1024;

fn load_roms(mem : []u8) !void {
    const dir = std.fs.cwd();
    _ = try dir.readFile("invaders.h", mem[0..]);
    _ = try dir.readFile("invaders.g", mem[rom_size..]);
    _ = try dir.readFile("invaders.f", mem[2*rom_size..]);
    _ = try dir.readFile("invaders.e", mem[3*rom_size..]);
}

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const render_scale = 3;

const pixel_w = 224;
const pixel_h = 256;

fn draw_screen(renderer: *c.SDL_Renderer, state: *machine.State) void {
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

fn graphics_main(state: *machine.State) !void {

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
    const tic = wallclock.time();
    var max_cycles : u64 = 0;
    var speed_up_factor : i32 = 1;

    while (!quit) {
        var buf: [32]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "frame {d} @ x{d}\x00", .{frame,speed_up_factor});
        c.SDL_SetWindowTitle(screen,&buf);
        draw_screen(renderer,state);
        c.SDL_RenderPresent(renderer);
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            //print("{any}\n",.{event});
            process_event(event, &state.buttons, &quit);
        }
        const cycles_per_display_frame = if (speed_up_factor < 0) 0 else
            2 * machine.half_frame_cycles * @as(u32,@intCast(speed_up_factor));
        frame+=1;
        max_cycles += cycles_per_display_frame;

        while (state.cycle <= max_cycles) {
            const enable_trace = false;
            machine.step(enable_trace, state);
        }

        const toc = wallclock.time();
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
        if (false) speed_up_factor = speed_up_factor + pause_ms;
    }
    print("event loop ended\n",.{});
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
