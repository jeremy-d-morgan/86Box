# 86Box Fork — Debug & Memory API: Build Plan

## Context

This document describes a plan for extending an existing 86Box fork with a debug and memory inspection API. The fork already has two additions in place:

- A `--headless` flag that suppresses the display window and activates a built-in VNC renderer
- A Unix domain socket VM management API (length-prefixed JSON protocol) with commands for VM control (`Pause`, `ResetVM`, `CtrlAltDel`, etc.) and floppy management (`FloppyInsert`, `FloppyEject`, `FloppyRefresh`)

The new work described here **extends the existing socket API** with debug and memory inspection capabilities. It does not introduce a new protocol or connection mechanism — it adds new message types to what already exists.

The eventual goal is to upstream this to mainline 86Box. Design decisions should keep that in mind.

---

## Design Goals

- **Extend the existing socket protocol** — new command types alongside `VMManager`, not a separate connection
- **Model the feature set on VICE's binary monitor** — VICE is the most mature remote debug protocol in the retro emulator space and covers the right features; take its command vocabulary as a checklist, not its wire format
- **Be x86-aware from the start** — segmented memory (segment:offset in real mode), multiple address spaces, and the x86 register set are first-class concerns; do not model this as a flat 16-bit address space
- **Make it upstreamable** — keep the implementation clean, opt-in, and minimally invasive to the existing codebase
- **Async event push** — the API should be able to push breakpoint-hit and status-change events to the client without polling

---

## Protocol Extension

### Existing message structure (for reference)

All messages on the socket are 4-byte big-endian length prefix + UTF-8 JSON body:

```json
{ "type": "VMManager", "message": "Pause" }
{ "type": "VMManager", "message": "FloppyInsert", "params": { "drive": 0, "path": "/path/to/image.vfd", "writeProtect": false } }
```

### New message type: `Debugger`

Add a `"type": "Debugger"` alongside `"type": "VMManager"`. Same framing, same connection.

**Request (client → 86Box):**
```json
{ "type": "Debugger", "id": 1, "message": "<Command>", "params": { ... } }
```

**Response (86Box → client):**
```json
{ "type": "DebuggerResponse", "id": 1, "ok": true, "data": { ... } }
{ "type": "DebuggerResponse", "id": 1, "ok": false, "error": "description" }
```

**Event push (86Box → client, unsolicited):**
```json
{ "type": "DebuggerEvent", "event": "BreakpointHit", "data": { ... } }
{ "type": "DebuggerEvent", "event": "Stepped", "data": { ... } }
{ "type": "DebuggerEvent", "event": "VMPaused", "data": { } }
{ "type": "DebuggerEvent", "event": "VMResumed", "data": { } }
```

The `id` field on requests allows clients to match responses to requests in an async context. 86Box echoes the `id` back in the response.

### Memory payload encoding

JSON is a poor fit for bulk memory reads. For commands that return raw memory bytes, encode the payload as base64 in the JSON response:

```json
{
  "type": "DebuggerResponse",
  "id": 3,
  "ok": true,
  "data": {
    "address": { "segment": "0x0000", "offset": "0x7C00" },
    "length": 512,
    "bytes": "<base64-encoded bytes>"
  }
}
```

This keeps the protocol uniform (all JSON) without needing a separate binary framing layer for memory data.

---

## x86 Memory Model

This is the most important design decision to get right upfront. x86 in real mode uses segmented addressing — a physical address is computed as `segment * 16 + offset`. The API must be explicit about this from day one.

### Address representation

All memory addresses in the API use a structured object, never a bare integer:

```json
{ "segment": "0xCS_VALUE", "offset": "0xIP_VALUE" }
```

For convenience, also accept a flat linear address:
```json
{ "linear": "0x07C00" }
```

The 86Box implementation resolves linear addresses to segment:offset using CS as the segment where applicable, or treats them as physical addresses directly where segmentation is not relevant (e.g. reading BIOS ROM).

### Address spaces

The API must distinguish between address spaces. Include an optional `"space"` field on memory commands:

| Space value | Description |
|---|---|
| `"ram"` | Conventional RAM (default if omitted) |
| `"rom"` | BIOS ROM area |
| `"vram"` | Video RAM |
| `"io"` | I/O port space (uses `port` field instead of address) |

---

## Commands to Implement

These are ordered by priority. Implement them in order — each tier is independently useful.

### Tier 1 — Execution control (highest priority)

These integrate with the existing `VMManager` pause/resume but expose finer-grained control.

| Command | Params | Description |
|---|---|---|
| `Break` | — | Pause emulation and enter debug state |
| `Continue` | — | Resume from debug state |
| `StepInto` | — | Execute one instruction, step into calls |
| `StepOver` | — | Execute one instruction, step over calls |

When `Break` is executed or a breakpoint is hit, 86Box sends a `BreakpointHit` or `Stepped` event with the current CPU state (registers + next instruction address).

### Tier 2 — Register inspection

| Command | Params | Response data |
|---|---|---|
| `GetRegisters` | — | Full x86 register state (see below) |
| `SetRegister` | `{ "register": "AX", "value": "0x1234" }` | Updated value |

**Register state object:**
```json
{
  "general": {
    "AX": "0x0000", "BX": "0x0000", "CX": "0x0000", "DX": "0x0000",
    "SI": "0x0000", "DI": "0x0000", "BP": "0x0000", "SP": "0x0000"
  },
  "segment": {
    "CS": "0x0000", "DS": "0x0000", "ES": "0x0000", "SS": "0x0000"
  },
  "pointer": {
    "IP": "0x0000"
  },
  "flags": {
    "raw": "0x0202",
    "CF": false, "PF": true, "AF": false, "ZF": false,
    "SF": false, "TF": false, "IF": true, "DF": false, "OF": false
  }
}
```

Note: for 386+ targets, extend with 32-bit registers (EAX etc.) and additional segment registers (FS, GS). Design the response object to be extensible — clients should ignore unknown fields.

### Tier 3 — Memory read/write

| Command | Params | Response data |
|---|---|---|
| `ReadMemory` | `{ "address": {...}, "length": 256, "space": "ram" }` | `{ "address": {...}, "length": 256, "bytes": "<base64>" }` |
| `WriteMemory` | `{ "address": {...}, "bytes": "<base64>", "space": "ram" }` | `{ "bytesWritten": 16 }` |
| `ReadPort` | `{ "port": "0x60", "width": 1 }` | `{ "port": "0x60", "value": "0xAA" }` |
| `WritePort` | `{ "port": "0x60", "value": "0xAA", "width": 1 }` | `{ "ok": true }` |

`width` for port I/O is 1, 2, or 4 bytes.

### Tier 4 — Breakpoints

| Command | Params | Description |
|---|---|---|
| `SetBreakpoint` | `{ "address": {...}, "type": "exec" }` | Set execution breakpoint |
| `SetBreakpoint` | `{ "address": {...}, "type": "read" }` | Set memory read watchpoint |
| `SetBreakpoint` | `{ "address": {...}, "type": "write" }` | Set memory write watchpoint |
| `RemoveBreakpoint` | `{ "id": 1 }` | Remove by ID |
| `ListBreakpoints` | — | Array of active breakpoints |
| `ClearBreakpoints` | — | Remove all |

`SetBreakpoint` response includes an `id` field for later removal.

When a breakpoint is hit, 86Box sends:
```json
{
  "type": "DebuggerEvent",
  "event": "BreakpointHit",
  "data": {
    "breakpointId": 1,
    "type": "exec",
    "address": { "segment": "0x0000", "offset": "0x7C00" },
    "registers": { ... }
  }
}
```

### Tier 5 — Disassembly (future / stretch)

| Command | Params | Description |
|---|---|---|
| `Disassemble` | `{ "address": {...}, "count": 10 }` | Disassemble N instructions from address |

Response is an array of instruction objects:
```json
[
  { "address": { "segment": "0x0000", "offset": "0x7C00" }, "bytes": "FA", "mnemonic": "CLI" },
  { "address": { "segment": "0x0000", "offset": "0x7C01" }, "bytes": "33C0", "mnemonic": "XOR AX, AX" }
]
```

86Box already has disassembly logic internally — this tier is about exposing it through the API.

---

## Implementation Approach

### Where to add code in the 86Box codebase

The existing socket API lives in a server/management module introduced by the fork. The new Debugger command type should be handled in the same message dispatch path — add a new handler branch for `"type": "Debugger"` alongside the existing `"type": "VMManager"` handler.

The actual debug operations (reading registers, reading memory, setting breakpoints) should call into 86Box's existing internal APIs rather than duplicating logic. 86Box already has internal access to CPU state and memory — the work is exposing it through the socket, not reimplementing it.

### Execution control and thread safety

86Box's CPU emulation runs on its own thread. Debug commands that read/write state must either:
- Pause the emulation thread before accessing state (`Break` command does this naturally), or
- Use 86Box's existing pause/resume primitives to ensure thread-safe access

Do not read CPU registers or memory from the socket handler thread while the emulation is running. Always pause first, operate, then allow resume.

### Opt-in activation

The debug API should only be active when the client explicitly enables it. Add a `DebuggerAttach` / `DebuggerDetach` handshake:

```json
{ "type": "Debugger", "id": 1, "message": "Attach" }
→ { "type": "DebuggerResponse", "id": 1, "ok": true, "data": { "version": "1.0", "cpu": "8088" } }
```

Until `Attach` is received, Debugger messages are ignored. This allows the socket to be used for VM management only without the overhead of debug state tracking.

---

## Design Notes for Upstreaming

When this is ready to propose to mainline 86Box:

- Frame it as a **general automation and tooling API**, not as a feature for any specific client. The use cases — CI testing of DOS software, external debugger frontends, automated regression testing — are compelling on their own merits.
- The VICE binary monitor precedent is worth citing: VICE's remote monitor is widely used and has spawned a healthy ecosystem of external tools. 86Box having an equivalent would enable the same.
- The existing floppy/VM management socket API is the foundation — the debug API is a natural extension of what's already there.
- Consider whether the GDB remote stub protocol is worth implementing as an alternative or complement. It would give 86Box compatibility with GDB, IDA, and a large ecosystem of existing tools for free, and is a strong upstream argument. The tradeoff is that GDB's x86 real-mode support is limited and the stub is more complex to implement correctly.

---

## Reference: VICE Binary Monitor Command Checklist

Use this as a feature completeness reference. For each VICE command, the x86 equivalent is noted where it differs.

| VICE command | x86 / 86Box equivalent | Tier |
|---|---|---|
| `MON_CMD_MEM_GET` | `ReadMemory` | 3 |
| `MON_CMD_MEM_SET` | `WriteMemory` | 3 |
| `MON_CMD_REGISTERS_GET` | `GetRegisters` | 2 |
| `MON_CMD_REGISTERS_SET` | `SetRegister` | 2 |
| `MON_CMD_EXIT` (resume) | `Continue` | 1 |
| `MON_CMD_STEP_INTO` | `StepInto` | 1 |
| `MON_CMD_STEP_OVER` | `StepOver` | 1 |
| `MON_CMD_BREAKPOINT_SET` | `SetBreakpoint` | 4 |
| `MON_CMD_BREAKPOINT_DELETE` | `RemoveBreakpoint` | 4 |
| `MON_CMD_BREAKPOINT_LIST` | `ListBreakpoints` | 4 |
| `MON_CMD_CHECKPOINT_TOGGLE` (watchpoints) | `SetBreakpoint` with `type: read/write` | 4 |
| `MON_CMD_DISASSEMBLE` | `Disassemble` | 5 |
| `MON_CMD_BANKS_AVAILABLE` | Not applicable — x86 uses segment:offset, not C64 banks | — |
| `MON_CMD_DISPLAY_GET` | Not planned — VNC covers display access | — |

VICE-specific commands with no x86 equivalent (PETSCII, sprite memory, SID registers, etc.) are omitted.