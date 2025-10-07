# zig-invaders

Emulation of Arcade Space-invaders using Zig.

See my [related project](https://github.com/Nick-Chapman/space-invaders) which uses Haskell
to first emulate and then statically recompile the Space Invader roms into C, for an impressive speed-up.

This new project is to gain more experience coding in Zig, and see how  Zig's `comptime` might be put to use to achieve a similar static recompilation.

But first we must write the baseline emulator for the 8080 CPU in Zig.

```
$ zig build-exe -O ReleaseFast invaders.zig
$ ./invaders speed
sim(s) = 876.840; wall(s) = 0.531; speed-up factor: x1652
```
