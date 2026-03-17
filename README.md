# zlice

**A terminal multiplexer under 100KB.**

Written in Zig. Zero dependencies. Statically linked. Runs on a Raspberry Pi Zero with 512MB RAM.

```
┌ fish ─────────────────────────────┐┌ vim ──────────────────────────────┐
│ ~/projects/zlice $ zig build      ││  1│ const std = @import("std");   │
│ Build succeeded                   ││  2│                               │
│ ~/projects/zlice $ _              ││  3│ pub fn main() !void {         │
│                                   ││~ ~                               │
├ logs ─────────────────────────────┤│                                   │
│ [2026-03-17] all tests passed     ││                                   │
│ ~/projects/zlice $                ││                                   │
└───────────────────────────────────┘└───────────────────────────────────┘
 Tab 1 [*]  Tab 2                    NORMAL  Ctrl+p:Pane | Ctrl+t:Tab
```

## Why

Measured on Raspberry Pi Zero 2W (aarch64), March 2026:

| | zlice | tmux 3.6a | zellij 0.43.1 |
|---|---|---|---|
| Binary | **93 KB** | 1.3 MB installed | 44 MB installed |
| Language | Zig | C | Rust + WASM |
| Runtime deps | **0** | libevent, ncurses | many |
| RSS (idle) | **~1 MB** | ~3 MB | ~40 MB |
| Text reflow | Yes | No | Yes |
| CJK width | Yes | Yes | Yes |

> Binary = static aarch64 `ReleaseSmall`. RSS = resident set of server process with one pane.
> tmux installed size from `pacman -Qi`. zellij binary `/usr/bin/zellij` = 44 MB.

## Features

- **Pane splitting** — horizontal, vertical, resize, focus navigation
- **Tabs** — create, close, switch, rename
- **Session persistence** — detach/attach, layout save/restore
- **Zellij-style modes** — NORMAL, PANE, TAB, SCROLL, SESSION, LOCKED
- **Text reflow** — content reflows when terminal width changes
- **Scrollback** — preserved on screen clear, scroll mode to browse history
- **CJK support** — fullwidth characters, Japanese input (fcitx5)
- **VT220 compatible** — SGR colors (256 + RGB), alternate screen, DA1/DSR
- **Alternate screen** — vim, htop, etc. restore correctly on exit
- **Single binary** — client/server in one executable, zero runtime dependencies

## Install

### Build from source

```bash
# Requires Zig 0.15+
git clone https://github.com/midasdf/zlice.git
cd zlice
zig build -Doptimize=ReleaseSmall
# Binary at zig-out/bin/zlice (<100KB)
```

### Cross-compile for ARM

```bash
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-gnu
# Static binary, runs on any aarch64 Linux
```

## Usage

```bash
zlice                    # Start new session
zlice attach <name>      # Attach to existing session
zlice list               # List sessions
```

### Keybindings

All modes return to NORMAL with `Esc` or `Enter`.

| Key | Mode | Action |
|-----|------|--------|
| `Ctrl+p` | → PANE | Pane operations |
| `Ctrl+t` | → TAB | Tab operations |
| `Ctrl+s` | → SCROLL | Browse scrollback |
| `Ctrl+o` | → SESSION | Detach/quit |
| `Ctrl+g` | → LOCKED | Pass all keys to PTY |

**PANE mode:**
`h/j/k/l` focus | `H/J/K/L` resize | `n` split-h | `v` split-v | `x` close

**TAB mode:**
`h/l` switch | `n` new | `x` close | `r` rename

**SCROLL mode:**
`j/k` line | `u/d` half-page | `PageUp/PageDown`

**SESSION mode:**
`d` detach | `q` quit

## Configuration

`~/.config/zlice/config.toml`

```toml
[general]
default_shell = "/bin/fish"
scrollback_lines = 1000
max_panes = 8

[appearance]
status_bar = true
pane_border_style = "single"

[keybinds]
pane_mode = "ctrl+p"
tab_mode = "ctrl+t"
scroll_mode = "ctrl+s"
```

## Architecture

```
Client (thin relay)          Server (owns everything)
┌──────────────┐             ┌──────────────────────┐
│ Raw mode     │◄──socket──►│ PTY management       │
│ Input parse  │             │ VT parser (custom)   │
│ Mode state   │             │ Grid (reflow engine) │
│              │             │ Screen compositor    │
└──────────────┘             │ Tab/Pane tree        │
                             └──────────────────────┘
```

Single binary, 17 source files, ~7400 lines of Zig. No external dependencies.

## License

MIT
