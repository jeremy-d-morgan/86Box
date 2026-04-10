# 86Box Fork Notes

Changes made on the `jeremy-dev` branch relative to upstream `master`.

---

## Floppy Insert / Eject / Refresh API

Extends the VMManager IPC protocol to allow external tools to control floppy
drive media programmatically, without user interaction in the UI.

### How it works

86Box already had a socket-based IPC system (`VMManagerClientSocket`) where it
connects outward to a manager application's socket. The manager sends JSON
commands and 86Box acts on them. We added three new command types to this
protocol, which call through to the same internal functions the UI uses when
you click the floppy menu or status bar button.

### New commands

| Command | Params | Description |
|---|---|---|
| `FloppyInsert` | `drive` (0–3), `path` (string), `writeProtect` (bool) | Insert a floppy image into a drive |
| `FloppyEject` | `drive` (0–3) | Eject the current image from a drive |
| `FloppyRefresh` | `drive` (0–3) | Eject and re-insert the current image (useful for forcing media change detection) |

Example JSON message:
```json
{ "type": "VMManager", "message": "FloppyInsert", "params": { "drive": 0, "path": "/path/to/image.vfd", "writeProtect": false } }
```

### Files changed

**`src/qt/qt_vmmanager_protocol.hpp`**
Added `FloppyInsert`, `FloppyEject`, and `FloppyRefresh` to the `ManagerMessage` enum.

**`src/qt/qt_vmmanager_protocol.cpp`**
Added string-to-enum matching for the three new message types in `getManagerMessageType()`.

**`src/qt/qt_vmmanager_clientsocket.hpp`**
Added three new signals: `floppyInsert(int drive, const QString &path, bool writeProtect)`, `floppyEject(int drive)`, `floppyRefresh(int drive)`.

**`src/qt/qt_vmmanager_clientsocket.cpp`**
Added handlers in `jsonReceived()` for the three new message types. Each extracts the `params` object from the JSON, validates the drive index, and emits the corresponding signal.

**`src/qt/qt_mediamenu.hpp`** / **`src/qt/qt_mediamenu.cpp`**
Added `floppyRefresh(int i)` — ejects the current image and re-mounts it. Insert and eject already existed as `floppyMount()` and `floppyEject()`.

**`src/qt/qt_mainwindow.hpp`** / **`src/qt/qt_mainwindow.cpp`**
Added three public slots (`floppyInsert`, `floppyEject`, `floppyRefresh`) that delegate to `MediaMenu`. This keeps `mm` private on `MainWindow` and follows the existing pattern used by other IPC-triggered actions.

**`src/qt/qt_main.cpp`**
Wired the three new `VMManagerClientSocket` signals to the corresponding `MainWindow` slots, alongside the existing connections for pause, reset, shutdown, etc.

---

## Headless Mode (`--headless`)

Adds a `--headless` command-line flag that runs 86Box with no display window,
no Qt widget stack, and no dependency on a graphical environment. Intended for
use in middleware, CI pipelines, SSH sessions, and VSCode extension hosting.

### How it works

A pre-scan of `argv` before `QApplication` is constructed detects `--headless`
and sets `QT_QPA_PLATFORM=offscreen` if no platform has already been specified.
The `offscreen` QPA provides a functioning Qt event loop with zero display
dependencies. A global `headless` flag (set in `pc_init()`) propagates through
the codebase to suppress the main window, skip blocking dialogs, and prevent
null-pointer crashes from code paths that assume a window exists.

When running headless with VNC enabled (see below), the libvncserver renderer
is selected automatically and initialized directly from the Qt event loop
timer without requiring a `MainWindow`.

### Files changed

**`src/include/86box/86box.h`**
Added `extern int headless;` global declaration.

**`src/86box.c`**
Added `int headless = 0;` definition and `--headless` parsing in `pc_init()`.
Added `--headless` to the usage string printed by `pc_show_usage()`.

**`src/qt/qt_main.cpp`**
- Pre-scans `argv` for `--headless` and sets `QT_QPA_PLATFORM=offscreen` before `QApplication` is constructed (required so the offscreen event loop fires `QTimer::singleShot` correctly on Wayland).
- `headless_display` boolean gates all `MainWindow` construction and signal wiring.
- Skips UUID mismatch dialog (calls `util::storeCurrentUuid()` directly) and ROM-not-found GUI dialog (prints to stderr instead) when headless.
- Skips CPU override warning dialog when headless.
- VMManager socket always connects; window-dependent signals are gated with `if (main_window != nullptr)`.
- `force_shutdown` / `request_shutdown` fall back to `QApplication::quit()` when `main_window` is null.
- Forces VNC renderer and calls `vnc_init()` directly when `headless_display` is true.
- Emulation starts paused in VNC mode and unpauses when the first VNC client connects.

**`src/qt/qt_ui.cpp`**
- `qt_blit()`: calls `video_blit_complete_monitor()` and returns immediately when headless (prevents emulation thread deadlock with no window to render into).
- All `main_window->` call sites guarded with `if (main_window == nullptr) return;`.
- `plat_resize_request()`, `ui_sb_update_text()`, `ui_sb_update_panes()`, `ui_sb_update_tip()`: null-guarded.

**`src/qt/qt_platform.cpp`**
- `plat_pause()`: `QTimer::singleShot` and `winId()` calls wrapped with `if (main_window != nullptr)`; `do_pause()` remains unconditional.
- `plat_power_off()`: falls back to `QApplication::quit()` when `main_window` is null.
- `plat_send_to_clipboard()`: early return when `main_window` is null.

**`src/qt/qt_mainwindow.cpp`**
Added `vnc` and `offscreen` to the platform list that forces the software renderer, preventing OpenGL/Vulkan initialisation on headless platforms.

---

## VNC Display (`-DVNC=ON`)

Extends the existing libvncserver-based VNC renderer (`src/vnc.c`) to work
reliably in headless mode. The VM's framebuffer is streamed over RFB to any
VNC client (TigerVNC, noVNC in a browser, etc.) without a display window.

This feature requires 86Box to be built with `-DVNC=ON` (links `libvncserver`).
Users running the standard build without VNC see no difference — the headless
mode still works, just without a display path.

### How it works

The VNC renderer is initialized directly from the Qt main thread (not via the
renderer menu) when `--headless` is active. libvncserver opens port 5900 and
runs its own event loop thread. When the first RFB client connects,
`vnc_newclient` fires and unpauses the emulator; when the last client
disconnects, the emulator pauses again.

The framebuffer is declared at the maximum supported size (2048×2048) for
the lifetime of the session. Dynamic resize (ExtDesktopSize) is suppressed
because libvncserver has no way to atomically discard already-queued
FramebufferUpdate rects before sending the new size notification — doing so
caused "rect too big" disconnects in all tested clients. Instead, `vnc_blit`
marks only the actual content area as modified and blits are clipped to fit.

Server-side cursor rendering is disabled: the VM renders its own cursor into
the framebuffer, and libvncserver's RichCursor path produced garbage-sized
rects (65535×65528) from an uninitialized cursor sprite. A valid 1×1
transparent cursor is installed at init so the initial cursor shape message
is well-formed; subsequent cursor updates are suppressed by the `displayHook`
clearing `cursorWasChanged` before every framebuffer update.

### Files changed

**`src/vnc.c`**
- Fixed null dereference in `vnc_init`: `ui_window_title(NULL)` return is now null-checked before `wcstombs`.
- Framebuffer declared at fixed 2048×2048; `vnc_resize` is a documented no-op.
- `vnc_blit` marks only the actual blit rect, not the full 2048×2048 canvas.
- `vnc_display` hook clears all cursor shape/position flags before every update, suppressing server-side cursor sends.
- `vnc_newclient` disables `enableCursorShapeUpdates`, `enableCursorPosUpdates`, `useRichCursorEncoding` immediately on connect.
- `rfbDefaultPtrAddEvent` call removed from `vnc_ptrevent` (it triggered the same corrupt cursor path).
- 1×1 transparent cursor installed via `rfbMakeXCursor` after `rfbInitServer`.
- `rfbSetCursor(rfb, NULL)` replaced with the transparent cursor (NULL caused rfbSendCursorShape to read garbage).
- Mouse absolute coordinates now computed from `VNC_MAX_X`/`VNC_MAX_Y` rather than removed `allowedX`/`allowedY` variables.
- `rfbReleaseClientIterator` was missing; added (was a minor resource leak).

### noVNC web viewer (`jeremy-dev/headless_test/`)

A minimal Node.js server that bridges noVNC (browser RFB client) to 86Box's
VNC port, allowing the VM display to appear inside a browser tab or VSCode
webview. This is the intended display path for the VSCode extension.

| File | Purpose |
|---|---|
| `headless_test/server.js` | HTTP static file server + WebSocket-to-TCP proxy (`/websockify`) |
| `headless_test/index.html` | noVNC viewer page with auto-reconnect |
| `headless_test/start.sh` | Launches 86Box headless + the Node.js server together |
| `headless_test/novnc/` | Browser ESM noVNC source (fetched via `npx degit novnc/noVNC#v1.5.0`) |

The websockify proxy explicitly sends binary WebSocket frames
(`ws.send(data, { binary: true })`) and retries TCP connections to port 5900
for up to 10 seconds, so connecting before 86Box has fully started does not
cause an immediate disconnect.

**Setup:**
```bash
cd jeremy-dev/headless_test
npm install ws
npx degit novnc/noVNC#v1.5.0 novnc
```

**Run:**
```bash
./start.sh /path/to/vm
# then open http://localhost:8080 in a browser
```
