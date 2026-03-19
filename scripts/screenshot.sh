#!/bin/bash
# Automated 720x720 screenshot of zplit inside zt on Xephyr
set -e

DISPLAY_NUM=":42"
SIZE="720x720"
ZT_BIN="$HOME/zt/zig-out/bin/zt"
ZPLIT_BIN="$HOME/zplit/zig-out/bin/zplit"
SCREENSHOT_DIR="$HOME/zplit/docs"
SCREENSHOT_PATH="$SCREENSHOT_DIR/screenshot.png"

mkdir -p "$SCREENSHOT_DIR"

# Kill previous instances
pkill -f "Xephyr $DISPLAY_NUM" 2>/dev/null || true
pkill -f "zplit --server" 2>/dev/null || true
rm -rf /tmp/zplit-* 2>/dev/null || true
sleep 0.5

# --- Left pane script (build output) ---
cat > /tmp/demo-left.sh << 'LEFT'
#!/bin/bash
clear
printf '\e[1;32mdemo@rpi\e[0m:\e[1;34m~/zplit\e[0m$ zig build -Doptimize=ReleaseSmall\n'
printf '\e[32mBuild Summary\e[0m: 3/3 steps succeeded\n'
printf '\n'
printf '\e[1;32mdemo@rpi\e[0m:\e[1;34m~/zplit\e[0m$ ls -lh zig-out/bin/zplit\n'
printf -- '-rwxr-xr-x 1 demo demo \e[1;33m97K\e[0m Mar 19 \e[1;32mzplit\e[0m\n'
printf '\n'
printf '\e[1;32mdemo@rpi\e[0m:\e[1;34m~/zplit\e[0m$ file zig-out/bin/zplit\n'
printf 'ELF aarch64, \e[33mstatically linked\e[0m, stripped\n'
printf '\n'
printf '\e[1;32mdemo@rpi\e[0m:\e[1;34m~/zplit\e[0m$ wc -l src/*.zig | tail -1\n'
printf '  \e[1m7409 total\e[0m\n'
printf '\n'
printf '\e[1;32mdemo@rpi\e[0m:\e[1;34m~/zplit\e[0m$ '
LEFT
chmod +x /tmp/demo-left.sh

# --- Right pane script (code view) ---
cat > /tmp/demo-right.sh << 'RIGHT'
#!/bin/bash
clear
printf '\e[90m 1\e[0m \e[34mconst\e[0m std = \e[33m@import\e[0m(\e[32m"std"\e[0m);\n'
printf '\e[90m 2\e[0m\n'
printf '\e[90m 3\e[0m \e[34mpub fn\e[0m \e[33mmain\e[0m() \e[34m!\e[0mvoid {\n'
printf '\e[90m 4\e[0m     \e[34mconst\e[0m srv = \e[34mtry\e[0m Server.init(a);\n'
printf '\e[90m 5\e[0m     \e[34mdefer\e[0m srv.deinit();\n'
printf '\e[90m 6\e[0m\n'
printf '\e[90m 7\e[0m     srv.run() \e[34mcatch\e[0m |err| {\n'
printf '\e[90m 8\e[0m         log.err(\e[32m"fatal: {}"\e[0m, .{err});\n'
printf '\e[90m 9\e[0m         \e[34mreturn\e[0m err;\n'
printf '\e[90m10\e[0m     };\n'
printf '\e[90m11\e[0m }\n'
printf '\e[90m12\e[0m\n'
printf '\e[90m13\e[0m \e[90m// 17 files, ~7400 LOC, <100KB\e[0m\n'
printf '\e[90m14\e[0m \e[34mconst\e[0m Server = \e[34mstruct\e[0m {\n'
printf '\e[90m15\e[0m     allocator: Allocator,\n'
printf '\e[90m16\e[0m     running: \e[34mbool\e[0m = \e[35mtrue\e[0m,\n'
printf '\e[90m17\e[0m     screen: Screen,\n'
printf '\e[90m18\e[0m\n'
printf '\e[90m19\e[0m     \e[34mpub fn\e[0m \e[33minit\e[0m(a: Allocator) \e[34m!\e[0mServer {\n'
printf '\e[90m20\e[0m         \e[34mreturn\e[0m .{ .allocator = a };\n'
printf '\e[90m21\e[0m     }\n'
printf '\e[90m22\e[0m };\n'
RIGHT
chmod +x /tmp/demo-right.sh

# --- Start Xephyr ---
Xephyr $DISPLAY_NUM -screen $SIZE -no-host-grab -title "zplit-screenshot" 2>/dev/null &
XEPHYR_PID=$!
sleep 1.5
DISPLAY=$DISPLAY_NUM xsetroot -solid black 2>/dev/null || true

# --- Start zt (fish shell inside) ---
DISPLAY=$DISPLAY_NUM TERM=xterm-256color ZPLIT=0 "$ZT_BIN" 2>/dev/null &
ZT_PID=$!
sleep 3

D="DISPLAY=$DISPLAY_NUM"

# Fish is running. Start zplit.
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 30 "$ZPLIT_BIN"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 4

# zplit is running. Run left demo in first pane.
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 20 "bash /tmp/demo-left.sh"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 2

# Vertical split: Ctrl+p, v
DISPLAY=$DISPLAY_NUM xdotool key ctrl+p
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key v
sleep 3

# Run right demo in second pane
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 20 "bash /tmp/demo-right.sh"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 2

# Focus left pane: Ctrl+p, h, Esc
DISPLAY=$DISPLAY_NUM xdotool key ctrl+p
sleep 0.5
DISPLAY=$DISPLAY_NUM xdotool key h
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 1.5

# Take screenshot
DISPLAY=$DISPLAY_NUM import -window root "$SCREENSHOT_PATH"
echo "Screenshot saved to: $SCREENSHOT_PATH"

# Clean up
kill $ZT_PID 2>/dev/null || true
sleep 0.3
kill $XEPHYR_PID 2>/dev/null || true
pkill -f "zplit --server" 2>/dev/null || true

# Restore zt config
sed -i 's|/bin/fish|/bin/sh|' "$HOME/zt/config.zig"

echo "Done!"
