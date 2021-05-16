# deinterlacer

Takes audio files that are interlaced and de-interlaces them into 2 separate files.

The audio files that use this format can be found in the BattleFront 1 (2004) and BattleFront 2 (2004).

This tool is written in Zig.  You can download the full compiler here: https://ziglang.org/download/.  It's statically compiled with no dependencies and should only be a few dozen megabytes.

# How to use

```
> zig build -p .
> deinterlace file.wav
```
