# AGENTS.md

Context and operating guide for this repository. Read this before changing code.

## What we are building

`openssm` is a **read-only Subaru diagnostics tool** in **Zig 0.15**, talking to a
**Tactrix OpenPort 2.0 (clone)** over USB. The goal is close to **1:1 parity with
the read functions of Subaru Select Monitor SSM3 and SSM4** for 2007+ vehicles,
covering the SSM2 (K-line), SSM3 (SSM-over-CAN), and SSM4 (UDS/ISO14229) eras.

Architecture is a **hardware daemon** that owns the OpenPort and speaks the
protocols, exposing a **JSON-lines IPC** endpoint (Unix socket or TCP) so many
clients can be built on top (CLI today, GUI/TUI/loggers later).

### Non-goals (for now)

- **No flash writes, no ECU programming.** Kernel upload / ROM dump is not
  implemented; do not add write paths without an explicit decision and a donor
  ECU.
- **No Windows/J2534/DLL emulation.** macOS-native only; no Wine, no vendor DLL.
- Not a general OBD-II scanner; the focus is Subaru SSM.

## Current status (2026-10-04)

Foundation is complete, compiling, formatted, and tested (28 unit tests).
**Hardware bring-up is done on a real clone** (firmware `1.17.4877`, CDC-ACM at
`/dev/cu.usbmodem*`, no libusb, no sudo).

Verified on hardware:

| Capability | Evidence |
|---|---|
| Identify | `ati <seq>` → `ari main code version : 1.17.4877` |
| Analog read | `atr 17 <seq>` → `arr 17 4117 <seq>`; pin 16 = VBATT (0 mV = no vehicle) |
| ISO9141 open | `ato3 1 4800 0 <seq>` → `aro <seq>`; `atg3 1` reads back `DATA_RATE 4800` |
| ISO15765 open | `ato6 1 500000 0 <seq>` → `aro <seq>`; `atg6 1` reads back `500000` |
| K-line SSM TX | `att3 6 0 100000 <seq>` + `80 10 F0 01 BF 40` → `aro <seq>` |
| CAN TX | `att6 …` → `are 9` (ERR_TIMEOUT) with no bus — expected, no ECU/ACK |

Not yet verified (needs the vehicle powered, VBATT ≈ 12 V):

- ECU **reply** to SSM init on K-line (`80 F0 10 … FF <5-byte ECU ID> …`).
- Address/block reads (SSM2), SSM-over-CAN (SSM3), UDS (SSM4).

## Hardware and protocol notes (hard-won, do not relearn)

- **macOS path:** the OpenPort enumerates as USB CDC-ACM → `/dev/cu.usbmodem*`.
  Open it with termios; the firmware ignores line coding, DTR+RTS is asserted.
  No libusb and no root are required on this path. (A vendor-specific / libusb
  fallback may be needed for some clones; not implemented.)
- **AT protocol:** line-oriented ASCII, every command ends with a sequence number
  `1..0xFFFF` that the device echoes. Commands end with `\r\n`; a binary payload
  (transmit/filter) is written **immediately after** the CRLF.
  Grammar: `ato<proto> <flags> <baud> <chan> <seq>` — **flags BEFORE baud**;
  read back `DATA_RATE` via `atg` to confirm.
- **Replies:** `aro <seq>` ok, `are <err> <seq>` error, `ari …` identify,
  `arr <pin> <mV> <seq>`, `arg<proto> <param> <val> <seq>`, `arf<proto> <id> <seq>`.
  Binary RX record: `'a' 'r' <proto-digit> <len> <RxStatus:1> <ts:4 BE> <id:4 BE> <data…>`
  with `len = 9 + data.len`.
- **Gotchas:**
  - `att` transmit timeout is microseconds and must be **nonzero**
    (`J2534_Timeout × 1000`); zero → immediate `ERR_TIMEOUT`.
  - The 4-byte CAN selector filter is **rejected on ISO9141**
    (`atf3 …` → `are 22` = `ERR_INVALID_FILTER_ID`); K-line forwards replies
    without a filter. A filter **is** required for CAN RX.
  - A transmit that times out can **wedge the firmware** (subsequent commands go
    silent). Recover with `atz <seq>` (device reset). `closeAll` (`ata`) is called
    at the start of a session for hygiene.
  - ISO14230 runs at **10400 baud only**; J1850 PWM/VPW and SW-CAN/SCI are
    unsupported by this firmware. Never send `atx` (bootloader).
- **SSM2 packet:** `0x80 dst src len cmd data… sum`, where `len = 1 + data.len`
  and `sum` = 8-bit sum of all preceding bytes. Source/dest: `0x10` ECU,
  `0x18` TCU, `0xF0` tool. Commands: `0xBF` init, `0xA8` addr read, `0xA0` block
  read, `0xB8`/`0xB0` writes (not implemented). Response cmds: `0xFF` init,
  `0xE8` addr read, `0xE0` block read.

Reference material (respect licenses):
- `roffe/libj2534_openport2` (Apache-2.0) — OpenPort AT protocol + RE notes.
- `firefighter-19/tuneforge` (GPL) — macOS Tactrix + Subaru SSM3-CAN/UDS behavior.
- RomRaider `log_defs.xml` / `ecu_defs.xml` — parameter + scaling database.
- RomRaider "SSM Protocol" wiki — SSM2 packet + scaling.

## Module map

```
src/ssm.zig        SSM2 packet framing, checksum, init/addrRead builders
src/openport.zig   OpenPort AT command builders + streaming reply/frame parser
src/transport.zig  Transport vtable; Mock (scripted) and AutoMock (synthesizes replies)
src/serial.zig     macOS/link serial transport (termios); firstCandidate autodetect
src/device.zig     Device state machine: seq, transact, open/close, analog, filter,
                   raw bring-up, RX frame queue
src/session.zig    SSM Link: openKline/openCan, send/recv, request (seq+cmd match)
src/ipc.zig        JSON-lines server (Unix socket / TCP), thread-per-connection
src/main.zig       CLI: probe, raw, kline, serve, mock-serve
www/               static project landing page
```

Data flow: `CLI/IPC → Device → Transport (Serial|Mock) → OpenPort`; `session.Link`
wraps `Device` with an open channel and SSM request/response semantics.

## Commands

```sh
zig build                 # build ./zig-out/bin/openssm
zig build test            # run all unit tests (must stay green)
zig fmt --check src build.zig

./zig-out/bin/openssm probe [--serial /dev/cu.usbmodem…]
./zig-out/bin/openssm raw "atr 16 99" [--hex AABB] [--serial PATH]
./zig-out/bin/openssm kline [--serial PATH]
./zig-out/bin/openssm serve [--serial PATH] [--unix /tmp/openssm.sock | --tcp 127.0.0.1:7878]
./zig-out/bin/openssm mock-serve [--unix /tmp/openssm.sock]
```

`--serial` is auto-detected from `/dev/cu.usbmodem*` / `usbserial*`.

## IPC contract (clients build against this)

One JSON object per line; one JSON response per line.

```
-> {"id":1,"method":"ping"}
<- {"id":1,"result":{"pong":true}}
-> {"id":2,"method":"probe"}
<- {"id":2,"result":{"firmware":"main code version : 1.17.4877","vbatt_mv":12300}}
-> {"id":3,"method":"analog","params":{"pin":16}}
<- {"id":3,"result":{"pin":16,"millivolts":12300}}
-> {"id":4,"method":"open","params":{"proto":3,"flags":1,"baud":4800,"chan":0}}
-> {"id":5,"method":"close","params":{"proto":3}}
-> {"id":6,"method":"closeAll"}
<- {"id":6,"result":{"ok":true}}
<- {"id":9,"error":{"message":"Timeout"}}
```

Keep responses additive; don't break existing field names.

## Conventions

- Zig **0.15.1**. Note the 0.15 API surfaces: new `std.Io` writers/readers,
  `std.net.Address.initUnix/.listen`, `std.json.Stringify.valueAlloc`,
  `std.posix.sigaction`. `error` is a keyword — use `@"error"` as a field name.
- Match surrounding style; no comments unless they encode a non-obvious fact
  (protocol quirks, offsets, why something is done a certain way).
- Every protocol behavior gets a unit test with a captured/exact byte vector.
  Tests run without hardware via `Mock` / `AutoMock`.
- **Verify on hardware** before claiming a protocol works; capture raw bytes with
  `openssm raw` and paste the evidence when relevant.
- Only commit when asked; keep the tree green (`zig build test`, `zig fmt`).

## Roadmap / next steps

1. **Live K-line read (next).** Plug into the car (VBATT ≈ 12 V), confirm the SSM
   init reply, implement `0xA8` address reads, decode params via RomRaider scaling.
2. **SSM3-CAN.** SSM-over-CAN request/response IDs over ISO15765; then UDS for
   2007+ (VIN, DTC mode 03/07/0A, freeze frame mode 02; SecurityAccess only if a
   read genuinely requires it).
3. **Parameter database.** Parse RomRaider `log_defs.xml` / `ecu_defs.xml`; expose
   named parameters + subscriptions over IPC.
4. **IPC streaming.** Subscribe/stream methods, optional msgpack framing.
5. **Packaging.** launchd daemon, stable socket path, permissions.
