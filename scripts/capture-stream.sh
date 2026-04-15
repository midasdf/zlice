#!/bin/bash
# Minimal reproducer for the pane border bug.
# Launches zplit inside zt on Xephyr, performs a single vertical split,
# captures the ANSI stream sent from server to client via ZPLIT_TEE_PATH,
# then also snapshots the screen right after the split.
#
# Artifacts:
#   /tmp/zplit-stream.log      — raw ANSI stream from server
#   ~/zplit/docs/bug-repro.png — screenshot at the buggy moment
set -e

DISPLAY_NUM=":43"
SIZE="800x600"
ZT_BIN="$HOME/.local/bin/zt-x11"
ZPLIT_BIN="$HOME/zplit/zig-out/bin/zplit"
TEE_PATH="/tmp/zplit-stream.log"
OUT_DIR="$HOME/zplit/docs"
SHOT="$OUT_DIR/bug-repro.png"

mkdir -p "$OUT_DIR"

pkill -f "Xephyr $DISPLAY_NUM" 2>/dev/null || true
pkill -f "zplit --server" 2>/dev/null || true
rm -f "$TEE_PATH" /tmp/zplit-*.sock 2>/dev/null || true
sleep 0.5

cat > /tmp/demo-left-min.sh << 'LEFT'
#!/bin/bash
printf '\033]0;fish\007'
clear
printf '\e[1;36m~/zplit\e[0m \e[1;35mmain\e[0m\n'
printf '\e[1;32m>\e[0m '
exec sleep infinity
LEFT
chmod +x /tmp/demo-left-min.sh

Xephyr $DISPLAY_NUM -screen $SIZE -no-host-grab -title "zplit-bug" 2>/dev/null &
XEPHYR_PID=$!
sleep 1.5
DISPLAY=$DISPLAY_NUM xsetroot -solid black 2>/dev/null || true

DISPLAY=$DISPLAY_NUM TERM=xterm-256color ZPLIT=0 "$ZT_BIN" 2>/dev/null &
ZT_PID=$!
sleep 3

ZT_WIN=$(DISPLAY=$DISPLAY_NUM xdotool search --class zt | head -1)
if [ -n "$ZT_WIN" ]; then
    DISPLAY=$DISPLAY_NUM xdotool windowmove "$ZT_WIN" 0 0 windowsize "$ZT_WIN" 800 600
    sleep 1
fi

# Launch zplit with the tee env var so every send payload is mirrored.
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 30 "ZPLIT_TEE_PATH=$TEE_PATH $ZPLIT_BIN"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 4

DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 20 "bash /tmp/demo-left-min.sh"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 2

# Mark the split boundary in the stream log with a recognizable sentinel
# via a harmless command — but env vars cannot be injected here, so we
# instead record a wall-clock timestamp and rely on byte offset for the
# split. Capture the current file size as the pre-split offset.
PRE_SPLIT_BYTES=$(stat -c %s "$TEE_PATH" 2>/dev/null || echo 0)
echo "[capture] pre-split bytes=$PRE_SPLIT_BYTES" >&2

# Vertical split: Ctrl+p, n
DISPLAY=$DISPLAY_NUM xdotool key ctrl+p
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key n
sleep 2

DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 1

# Capture the buggy frame
DISPLAY=$DISPLAY_NUM import -window root "$SHOT"
echo "[capture] screenshot: $SHOT" >&2

POST_BYTES=$(stat -c %s "$TEE_PATH" 2>/dev/null || echo 0)
echo "[capture] post-split bytes=$POST_BYTES" >&2
echo "$PRE_SPLIT_BYTES" > /tmp/zplit-stream.presplit

kill $ZT_PID 2>/dev/null || true
sleep 0.3
kill $XEPHYR_PID 2>/dev/null || true
pkill -f "zplit --server" 2>/dev/null || true
echo "[capture] done"
