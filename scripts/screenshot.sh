#!/bin/bash
# Automated 720x720 screenshot of zplit inside zt on Xephyr
set -e

DISPLAY_NUM=":42"
SIZE="800x600"
ZT_BIN="$HOME/.local/bin/zt-x11"
ZPLIT_BIN="$HOME/zplit/zig-out/bin/zplit"
SCREENSHOT_DIR="$HOME/zplit/docs"
SCREENSHOT_PATH="$SCREENSHOT_DIR/screenshot.png"

mkdir -p "$SCREENSHOT_DIR"

# Kill previous instances
pkill -f "Xephyr $DISPLAY_NUM" 2>/dev/null || true
pkill -f "zplit --server" 2>/dev/null || true
rm -rf /tmp/zplit-* 2>/dev/null || true
sleep 0.5

# --- Tab 1 Left pane: development workflow ---
cat > /tmp/demo-left.sh << 'LEFT'
#!/bin/bash
printf '\033]0;fish\007'
clear

printf '\e[1;36m~/zplit\e[0m \e[1;35mmain\e[0m\n'
printf '\e[1;32m>\e[0m git log --oneline -7\n'
printf '\e[33mfd9a80e\e[0m fix: scrollback reflow\n'
printf '\e[33md1b5b4b\e[0m fix: clear pushes content\n'
printf '\e[33m0245b9e\e[0m fix: reflow gap on split\n'
printf '\e[33m8000fc3\e[0m docs: update screenshot\n'
printf '\e[33m716b5a3\e[0m rename: zlice -> zplit\n'
printf '\e[33m64c822c\e[0m fix: code review - bugs\n'
printf '\e[33ma38edc3\e[0m fix: remove dead code\n'
printf '\n'

printf '\e[1;36m~/zplit\e[0m \e[1;35mmain\e[0m\n'
printf '\e[1;32m>\e[0m zig build -Doptimize=ReleaseSmall\n'
printf '\e[32mBuild Summary\e[0m: 3/3 succeeded\n'
printf '\n'

printf '\e[1;36m~/zplit\e[0m \e[1;35mmain\e[0m\n'
printf '\e[1;32m>\e[0m ls -lh zig-out/bin/zplit\n'
printf -- '-rwxr-xr-x \e[1;33m97K\e[0m \e[1;32mzplit\e[0m\n'
printf '\n'

printf '\e[1;36m~/zplit\e[0m \e[1;35mmain\e[0m\n'
printf '\e[1;32m>\e[0m file zig-out/bin/zplit\n'
printf 'ELF aarch64, \e[33mstatically linked\e[0m\n'
printf '\n'

printf '\e[1;36m~/zplit\e[0m \e[1;35mmain\e[0m\n'
printf '\e[1;32m>\e[0m '
exec sleep infinity
LEFT
chmod +x /tmp/demo-left.sh

# --- Tab 1 Right pane: syntax-highlighted pane.zig ---
cat > /tmp/demo-right.sh << 'RIGHT'
#!/bin/bash
printf '\033]0;src/pane.zig\007'
clear

C='\e[90m'   # line numbers (gray)
K='\e[34m'   # keywords (blue)
T='\e[33m'   # types (yellow)
S='\e[32m'   # strings (green)
P='\e[35m'   # pub (magenta)
N='\e[0m'    # reset

printf "${C} 1${N} ${K}const${N} std = ${K}@import${N}(${S}\"std\"${N});\n"
printf "${C} 2${N}\n"
printf "${C} 3${N} ${P}pub const${N} Region = ${K}struct${N} {\n"
printf "${C} 4${N}     row: ${T}u16${N},\n"
printf "${C} 5${N}     col: ${T}u16${N},\n"
printf "${C} 6${N}     rows: ${T}u16${N},\n"
printf "${C} 7${N}     cols: ${T}u16${N},\n"
printf "${C} 8${N} };\n"
printf "${C} 9${N}\n"
printf "${C}10${N} ${P}pub const${N} SplitDir = ${K}enum${N} {\n"
printf "${C}11${N}     horizontal,\n"
printf "${C}12${N}     vertical,\n"
printf "${C}13${N} };\n"
printf "${C}14${N}\n"
printf "${C}15${N} ${P}pub const${N} LayoutNode =\n"
printf "${C}16${N}     ${K}union${N}(${K}enum${N}) {\n"
printf "${C}17${N}     leaf: LeafData,\n"
printf "${C}18${N}     split: SplitData,\n"
printf "${C}19${N}\n"
printf "${C}20${N}     ${P}pub const${N} LeafData =\n"
printf "${C}21${N}         ${K}struct${N} {\n"
printf "${C}22${N}         id: PaneId,\n"
printf "${C}23${N}         pty_fd: ${T}i32${N},\n"
printf "${C}24${N}     };\n"
printf "${C}25${N}\n"
printf "${C}26${N}     ${P}pub const${N} SplitData =\n"
printf "${C}27${N}         ${K}struct${N} {\n"
printf "${C}28${N}         dir: SplitDir,\n"
printf "${C}29${N}         ratio: ${T}f32${N},\n"
printf "${C}30${N}         first: *LayoutNode,\n"
printf "${C}31${N}         second: *LayoutNode,\n"
printf "${C}32${N}     };\n"
printf "${C}33${N} };\n"

exec sleep infinity
RIGHT
chmod +x /tmp/demo-right.sh

# --- Tab 2: system info (HackberryPi Zero) ---
cat > /tmp/demo-tab2.sh << 'TAB2'
#!/bin/bash
printf '\033]0;anzu\007'
clear

W='\e[1;37m'  # white bold
C='\e[1;36m'  # cyan bold
G='\e[1;32m'  # green bold
Y='\e[1;33m'  # yellow bold
M='\e[1;35m'  # magenta bold
R='\e[0;31m'  # red
D='\e[90m'    # dim
N='\e[0m'     # reset
B='\e[32m'    # green bar
E='\e[90m'    # empty bar

printf "\n"
printf "  ${G}      .---.      ${C}midasdf${N}@${C}anzu${N}\n"
printf "  ${G}     /     \\     ${D}──────────────────${N}\n"
printf "  ${G}    |  RPi  |    ${M}OS${N}     Arch Linux ARM\n"
printf "  ${G}    |  Zero |    ${M}Host${N}   RPi Zero 2W\n"
printf "  ${G}     \\ 2W  /     ${M}Kernel${N} 6.18.16-2-rpi\n"
printf "  ${G}      '---'      ${M}Shell${N}  fish 4.0\n"
printf "  ${G}    HackberryPi  ${M}Term${N}   zt + zplit\n"
printf "  ${G}                 ${M}WM${N}     i3\n"
printf "  ${G}   ┌──────────┐  ${M}CPU${N}    BCM2710A1 1.2GHz\n"
printf "  ${G}   │ 720x720  │  ${M}Memory${N} 148M / 445M\n"
printf "  ${G}   │ HyperPx4 │  ${N}        ${B}######${E}##########${N}\n"
printf "  ${G}   └──────────┘  ${M}Swap${N}   82M / 1.4G\n"
printf "  ${G}   ┌──────────┐  ${N}        ${B}##${E}##############${N}\n"
printf "  ${G}   │ keyboard │  ${M}Disk${N}   4.2G / 29G\n"
printf "  ${G}   │  P9981   │  ${N}        ${B}####${E}############${N}\n"
printf "  ${G}   └──────────┘  ${M}Uptime${N} 3d 14h 22m\n"
printf "\n"

printf "  ${D}──────────────────────────────────${N}\n"
printf "  ${C}zplit sessions${N}\n"
printf "  ${W}SESSION   PANES  CREATED${N}\n"
printf "  ${G}dev${N}       2      3h ago\n"
printf "  ${Y}monitor${N}   1      1d ago\n"
printf "\n"

printf "  ${C}~${N}\n"
printf "  ${G}>${N} "
exec sleep infinity
TAB2
chmod +x /tmp/demo-tab2.sh

# --- Start Xephyr ---
Xephyr $DISPLAY_NUM -screen $SIZE -no-host-grab -title "zplit-screenshot" 2>/dev/null &
XEPHYR_PID=$!
sleep 1.5
DISPLAY=$DISPLAY_NUM xsetroot -solid black 2>/dev/null || true

# --- Start zt ---
DISPLAY=$DISPLAY_NUM TERM=xterm-256color ZPLIT=0 "$ZT_BIN" 2>/dev/null &
ZT_PID=$!
sleep 3

# Resize zt window to fill Xephyr (no WM in Xephyr, so xdotool handles it)
ZT_WIN=$(DISPLAY=$DISPLAY_NUM xdotool search --class zt | head -1)
if [ -n "$ZT_WIN" ]; then
    DISPLAY=$DISPLAY_NUM xdotool windowmove "$ZT_WIN" 0 0 windowsize "$ZT_WIN" 800 600
    sleep 1
fi

# Start zplit
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 30 "$ZPLIT_BIN"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 4

# ===== Tab 1: Development workflow =====

# Run left demo
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 20 "bash /tmp/demo-left.sh"
sleep 0.3
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 2

# Split left/right: Ctrl+p, n
DISPLAY=$DISPLAY_NUM xdotool key ctrl+p
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key n
sleep 4

# Exit PANE mode
DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 1

# Run right demo
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 20 "bash /tmp/demo-right.sh"
sleep 0.5
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 3

# ===== Tab 2: System info =====

# Create new tab: Ctrl+t, n
DISPLAY=$DISPLAY_NUM xdotool key ctrl+t
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key n
sleep 4

# Exit TAB mode
DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 1

# Run tab2 demo
DISPLAY=$DISPLAY_NUM xdotool type --clearmodifiers --delay 20 "bash /tmp/demo-tab2.sh"
sleep 0.5
DISPLAY=$DISPLAY_NUM xdotool key Return
sleep 3

# ===== Switch back to Tab 1 =====
DISPLAY=$DISPLAY_NUM xdotool key ctrl+t
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key h
sleep 0.5
DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 1

# Focus left pane on Tab 1
DISPLAY=$DISPLAY_NUM xdotool key ctrl+p
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key h
sleep 0.5
DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 2

# Take screenshot of Tab 1 (tab bar shows both tabs)
DISPLAY=$DISPLAY_NUM import -window root "$SCREENSHOT_PATH"
echo "Screenshot 1 (Tab 1) saved to: $SCREENSHOT_PATH"

# Switch to Tab 2 and take second screenshot
DISPLAY=$DISPLAY_NUM xdotool key ctrl+t
sleep 1
DISPLAY=$DISPLAY_NUM xdotool key l
sleep 0.5
DISPLAY=$DISPLAY_NUM xdotool key Escape
sleep 2

DISPLAY=$DISPLAY_NUM import -window root "$SCREENSHOT_DIR/screenshot-tab2.png"
echo "Screenshot 2 (Tab 2) saved to: $SCREENSHOT_DIR/screenshot-tab2.png"

# Clean up
kill $ZT_PID 2>/dev/null || true
sleep 0.3
kill $XEPHYR_PID 2>/dev/null || true
pkill -f "zplit --server" 2>/dev/null || true

echo "Done!"
