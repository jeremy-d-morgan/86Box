# 86Box Fork — Agent Onboarding

This document is for AI agents joining this project. It covers what has been built, why, what the architecture looks like, and the pitfalls to avoid.

---

## What is this?

A fork of [86Box](https://github.com/86Box/86Box), an x86 PC hardware emulator. The fork adds capabilities needed to run 86Box as a **headless backend** controlled by external tools — specifically a VSCode extension that embeds the VM display in a webview tab.

**Branch:** `jeremy-dev-headless` (based on upstream `master`)

**End goal:** A VSCode extension where you can boot a retro PC, see its display in a browser-based viewer, interact with keyboard/mouse, and control floppy drives and (eventually) debug the guest CPU — all without 86Box's native Qt GUI.

---

## What has been built

Three features, all on the same branch:

### 1. Floppy Insert / Eject / Refresh API

Extends 86Box's existing VMManager IPC socket protocol with three new commands for programmatic floppy drive control.

| Command | Params | What it does |
|---|---|---|
| `FloppyInsert` | `drive` (0–3), `path`, `writeProtect` | Mount a floppy image |
| `FloppyEject` | `drive` (0–3) | Eject current image |
| `FloppyRefresh` | `drive` (0–3) | Eject + re-insert (forces media change detection) |

**Protocol:** 4-byte big-endian length prefix + UTF-8 JSON body over Unix domain socket.

```json
{ "type": "VMManager", "message": "FloppyInsert", "params": { "drive": 0, "path": "/path/to/image.vfd", "writeProtect": false } }
```

**Files changed:**
- `src/qt/qt_vmmanager_protocol.hpp` — enum entries
- `src/qt/qt_vmmanager_protocol.cpp` — string→enum mapping
- `src/qt/qt_vmmanager_clientsocket.hpp` / `.cpp` — signals + JSON handlers
- `src/qt/qt_mediamenu.hpp` / `.cpp` — `floppyRefresh()` method
- `src/qt/qt_mainwindow.hpp` / `.cpp` — public slots that delegate to MediaMenu
- `src/qt/qt_main.cpp` — signal→slot wiring

### 2. Headless Mode (`--headless`)

Runs 86Box with no display window, no Qt widget stack, no X11/Wayland dependency.

**How it works:**
- Pre-scan of `argv` before `QApplication` construction detects `--headless`
- Sets `QT_QPA_PLATFORM=offscreen` — Qt's offscreen QPA gives a functioning event loop with zero display dependencies
- Global `int headless` flag (declared in `86box.h`, set in `pc_init()`) propagates through codebase
- All `MainWindow` construction, signal wiring, and GUI dialogs are gated on this flag
- `main_window` is NULL throughout — every call site that dereferences it has been null-guarded

**Critical implementation details:**
- `qt_blit()` must call `video_blit_complete_monitor()` and return immediately when headless, or the emulation thread deadlocks waiting for the blit event
- `force_shutdown` / `request_shutdown` fall back to `QApplication::quit()` when `main_window` is null
- Blocking dialogs (UUID mismatch, ROM not found, CPU override) are replaced with stderr output or silent fallbacks
- VMManager socket always connects; window-dependent signals are gated with `if (main_window != nullptr)`

**Files changed:**
- `src/include/86box/86box.h` — `extern int headless;`
- `src/86box.c` — flag definition, `--headless` parsing in `pc_init()`
- `src/qt/qt_main.cpp` — most of the headless gating logic
- `src/qt/qt_ui.cpp` — null guards on all `main_window->` call sites
- `src/qt/qt_platform.cpp` — null guards on `plat_pause()`, `plat_power_off()`, etc.
- `src/qt/qt_mainwindow.cpp` — `vnc`/`offscreen` added to software renderer platform list

### 3. VNC Display (`-DVNC=ON`)

Streams the VM framebuffer over RFB (VNC protocol) using libvncserver. This is the display path for headless mode.

**How it works:**
- When `--headless` is active, the VNC renderer is initialized directly from the Qt main thread
- libvncserver opens port 5900 and runs its own event loop thread
- First client connect → unpauses emulator; last client disconnect → pauses
- Framebuffer is allocated at 2048×2048 (the maximum); `rfb->width`/`rfb->height` track the current video mode
- Dynamic resize via `ExtDesktopSize`: when the VM changes video mode, `vnc_resize()` updates dimensions and sets `newFBSizePending` on all clients
- `vnc_blit()` performs nearest-neighbor stretch from native pixel dimensions to the declared canvas size (handles 4:3 aspect ratio correction via `force_43`)

**Build requirement:** `-DVNC=ON` in the cmake command (links `libvncserver`).

**Files changed:**
- `src/vnc.c` — the primary file; all VNC rendering logic
- `src/qt/qt_ui.cpp` — `plat_resize_request()` calls `vnc_resize()` when headless
- `src/86box.c` — `force_43` defaulted to 1

---

## The noVNC Web Viewer

Located at `jeremy-dev/headless_test/`. A minimal Node.js server that bridges noVNC (browser RFB client) to 86Box's VNC port.

| File | Purpose |
|---|---|
| `server.js` | HTTP static server + WebSocket-to-TCP proxy (`/websockify`) |
| `index.html` | noVNC viewer with zoom controls and auto-reconnect |
| `start.sh` | Launches 86Box headless + Node.js server together |
| `novnc/` | Browser ESM noVNC source (fetched via `npx degit novnc/noVNC#v1.5.0`) |

**Key viewer features:**
- Scale presets: 0.25×, 0.5×, 0.75×, 1×, 1.5×, 2×, 3×, 4×
- Fill mode: expands to viewport, letterboxed, centered, aspect-ratio-preserving
- `image-rendering: pixelated` for crisp nearest-neighbor scaling
- `MutationObserver` on canvas `width`/`height` attributes — reapplies scale on resolution change
- Auto-reconnect after 2s on disconnect

**Setup:**
```bash
cd jeremy-dev/headless_test
npm install ws
npx degit novnc/noVNC#v1.5.0 novnc
```

---

## Building

```bash
cd jeremy-dev
./build.sh
```

This runs cmake with `-DVNC=ON` and builds with Ninja. Output goes to `~/86Box/86Box-dev-latest`.

Or manually:
```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DUSE_QT6=ON -DVNC=ON
ninja -j$(nproc) -C build
```

---

## Running

**Headless with VNC:**
```bash
~/86Box/86Box-dev-latest --headless -P /path/to/vm/directory
```
Then connect a VNC client to `localhost:5900`.

**With the noVNC viewer:**
```bash
cd jeremy-dev/headless_test
./start.sh /path/to/vm/directory
# Open http://localhost:8080
```

**Normal GUI mode** (unchanged from upstream):
```bash
~/86Box/86Box-dev-latest -P /path/to/vm/directory
```

---

## Architecture: Video Pipeline in Headless Mode

Understanding this pipeline is essential for working on VNC display issues:

```
Video card emulation
  → writes to buffer32 (internal framebuffer)
  → calls video_setblit callback (vnc_blit)
    → vnc_blit receives native pixel dimensions (w × h)
    → reads rfb->width / rfb->height (force_43-corrected canvas size)
    → nearest-neighbor stretches buffer32 → rfb->frameBuffer
    → calls rfbMarkRectAsModified to notify VNC clients
    → calls video_blit_complete_monitor to unblock emulation thread

Resolution change path:
  set_screen_size_monitor()
    → computes force_43-corrected dimensions (e.g., 720×400 → 720×540)
    → calls plat_resize_request(w, h)
    → plat_resize_request calls vnc_resize(w, h) when headless
    → vnc_resize updates rfb->width/height, sets newFBSizePending on clients
    → VNC clients receive ExtDesktopSize pseudo-encoding
```

**Important:** `vnc_blit` receives the **native** pixel dimensions from the emulation core, but the VNC canvas (`rfb->width`/`rfb->height`) may be a different size due to `force_43` aspect ratio correction. The stretch in `vnc_blit` bridges this gap.

---

## Architecture: IPC Socket Protocol

86Box connects outward to a manager application's Unix domain socket. The manager sends JSON commands and 86Box acts on them.

```
External tool (VSCode extension, script, etc.)
  ← listens on Unix domain socket
  ← 86Box connects to it on startup (VMManagerClientSocket)
  → sends length-prefixed JSON commands
  ← receives responses

Message format: [4-byte big-endian length][UTF-8 JSON body]

Types: "VMManager" (existing: Pause, ResetVM, CtrlAltDel, etc. + new: FloppyInsert/Eject/Refresh)
       "Debugger" (planned — see jeremy-dev/docs/debugger.md)
```

---

## Known Pitfalls and Hard-Won Lessons

These are things that caused significant debugging time. Read them before touching VNC or headless code.

### libvncserver cursor handling causes "rect too big" crashes

libvncserver's RichCursor encoding computes cursor rect dimensions from the `rfb->cursor` struct. If the cursor is NULL or uninitialized, it reads garbage and sends rects like 65535×65528, causing clients to disconnect with "rect too big".

**What we do:** Install a valid 1×1 transparent cursor via `rfbMakeXCursor(1, 1, " ", " ")` after `rfbInitServer`. The `displayHook` (`vnc_display`) clears all cursor shape/position flags before every framebuffer update, so the cursor is sent once and never again.

**Do not:**
- Call `rfbSetCursor(rfb, NULL)` — this is what causes the garbage reads
- Call `rfbDefaultPtrAddEvent` in the pointer event handler — it triggers the same corrupt cursor path
- Re-enable cursor shape updates — libvncserver's `SetEncodings` handler re-enables them after `newClientHook` returns, which is why the `displayHook` must clear them every frame

### video_blit_complete_monitor must always be called

`vnc_blit` (or any blit callback) must call `video_blit_complete_monitor(monitor_index)` on every invocation, even in error/early-return paths. If it doesn't, the emulation thread blocks forever waiting for the blit event.

### rfbGetScreen paddedWidthInBytes vs rfb->width

`rfbGetScreen` computes `paddedWidthInBytes` from the initial width parameter. If you later change `rfb->width` to something larger, `rfbMarkRectAsModified` can produce rects that exceed the actual stride, causing "rect too big" on clients. We solve this by declaring the screen at VNC_MAX_X × VNC_MAX_Y (2048×2048) at init and only reducing `rfb->width`/`rfb->height` for the active video mode.

### rfbMarkRectAsModified takes (x1, y1, x2, y2), not (x, y, w, h)

Self-explanatory but easy to get wrong.

### QT_QPA_PLATFORM must be set before QApplication construction

The `--headless` pre-scan of argv sets `QT_QPA_PLATFORM=offscreen` before `QApplication` is constructed. This is required because the offscreen QPA must be selected during Qt initialization, not after. On Wayland in particular, constructing QApplication with the default platform and then switching later causes `QTimer::singleShot` to silently fail.

### The `scale` variable should not be changed in code

86Box's `scale` variable (0=50%, 1=100%, 2=150%) interacts with `plat_resize_request` in ways that can trigger mid-session resizes. Changing the default in code caused "rect too big" errors. Users should set `scale` in their VM's `86box.cfg` instead. `force_43` is safe to change in code (we default it to 1).

---

## Planned Work

### Debug & Memory API (next major feature)

Documented in detail at `jeremy-dev/docs/debugger.md`. Extends the existing IPC socket protocol with a `"type": "Debugger"` message type for:
- Execution control (break, continue, step into/over)
- Register inspection and modification
- Memory read/write with x86 segmented addressing
- Breakpoints and watchpoints
- Disassembly

### VSCode Extension

The end goal. Will embed the noVNC viewer in a webview tab and provide:
- VM display via noVNC WebSocket connection
- Floppy drive management via the IPC socket
- Debug controls via the planned Debugger API
- Configuration UI for VM settings

---

## File Map

Quick reference for where things live:

| Area | Key files |
|---|---|
| Headless flag | `src/include/86box/86box.h`, `src/86box.c` |
| Headless gating | `src/qt/qt_main.cpp`, `src/qt/qt_ui.cpp`, `src/qt/qt_platform.cpp` |
| VNC renderer | `src/vnc.c`, `src/include/86box/vnc.h` |
| VNC resize integration | `src/qt/qt_ui.cpp` (`plat_resize_request`) |
| Floppy API protocol | `src/qt/qt_vmmanager_protocol.hpp/.cpp` |
| Floppy API socket | `src/qt/qt_vmmanager_clientsocket.hpp/.cpp` |
| Floppy API wiring | `src/qt/qt_mainwindow.hpp/.cpp`, `src/qt/qt_main.cpp` |
| Floppy media ops | `src/qt/qt_mediamenu.hpp/.cpp` |
| noVNC viewer | `jeremy-dev/headless_test/` |
| Build script | `jeremy-dev/build.sh` |
| Fork documentation | `jeremy-dev/FORK.md` |
| Debug API plan | `jeremy-dev/docs/debugger.md` |

---

## Key Configuration

**VM config (`86box.cfg`):**
- `force_43 = 1` — 4:3 aspect ratio correction (now on by default in code)
- `scale = 0` — 50% scale (default; set to 1 for 100% if desired)
- VNC port is always 5900 (hardcoded in libvncserver defaults)

**Build options:**
- `-DVNC=ON` — required for VNC display support (links libvncserver)
- `-DUSE_QT6=ON` — Qt6 build
- `-DCMAKE_BUILD_TYPE=RelWithDebInfo` — debug symbols with optimization

---

## Testing Checklist

When making changes to headless/VNC code, verify:

- [ ] 86Box starts in headless mode without a display server (`--headless`)
- [ ] VNC client (TigerVNC or noVNC) can connect to port 5900
- [ ] Display is visible and correctly aspect-ratio'd (not squished)
- [ ] Resolution changes in the VM (e.g., switching video modes) update the VNC display
- [ ] Keyboard input works through VNC
- [ ] Mouse input works through VNC
- [ ] Disconnecting and reconnecting the VNC client works without crashes
- [ ] Emulator pauses when last VNC client disconnects, resumes when one connects
- [ ] No "rect too big" errors in VNC client logs
- [ ] Clean shutdown (Ctrl+C or VM power off) exits without hanging
- [ ] Normal GUI mode still works (no regressions from headless changes)
