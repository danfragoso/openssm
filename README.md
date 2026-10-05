# openssm

A **read-only Subaru Select Monitor** reader for macOS, written in **Zig 0.15**.
It talks to a **Tactrix OpenPort 2.0** (or clone) over USB and exposes a
**JSON-lines IPC** endpoint so any number of clients can consume live SSM data.

The target is close to 1:1 parity with the **read** functions of Subaru Select
Monitor **SSM3 / SSM4** for 2007+ vehicles, spanning the SSM2 (K-line),
SSM3 (SSM-over-CAN), and SSM4 (UDS/ISO14229) eras.

> Read-only by design. No flash writes, no ECU programming, ever.

## Status

Foundation done, running on real hardware. The OpenPort clone is driven over its
CDC-ACM serial interface (no libusb, no sudo on macOS), and the AT command layer
is verified: identify, analog reads, ISO9141/ISO15765 channel open, and K-line
SSM transmit.

Still to land: the first live ECU read (needs the vehicle powered), SSM-over-CAN
and UDS decoders, and the RomRaider parameter database.

See [`AGENTS.md`](AGENTS.md) for the full project state, architecture, hardware
notes, and roadmap.

## Requirements

- macOS (Apple Silicon or Intel) with Zig **0.15.1**
- A Tactrix OpenPort 2.0 or compatible clone

## Build

```sh
zig build          # -> ./zig-out/bin/openssm
zig build test     # run the unit tests (28, no hardware needed)
```

## Use

```sh
# Device info + battery voltage
./zig-out/bin/openssm probe

# Bring-up: send a raw AT command, optionally with a binary payload
./zig-out/bin/openssm raw "atr 16 99"
./zig-out/bin/openssm raw "att3 6 0 100000 42" --hex 8010F001BF40

# Open the K-line SSM channel and send the ECU init
./zig-out/bin/openssm kline

# Serve JSON-lines IPC over a Unix socket (or --tcp 127.0.0.1:7878)
./zig-out/bin/openssm serve --unix /tmp/openssm.sock

# Same, but with a synthetic device so clients can be developed with no hardware
./zig-out/bin/openssm mock-serve --unix /tmp/openssm.sock
```

`--serial` is auto-detected from `/dev/cu.usbmodem*` / `usbserial*`.

### IPC example

```sh
printf '{"id":1,"method":"probe"}\n' | nc -U /tmp/openssm.sock
# {"id":1,"result":{"firmware":"main code version : 1.17.4877","vbatt_mv":0}}
```

## Architecture

```
CLI / IPC clients
      │  JSON lines (Unix socket / TCP)
      ▼
   ipc.zig ── session.zig ── device.zig ── transport.zig
                                              │
                                    serial.zig ▼  (macOS CDC-ACM)
                                          OpenPort 2.0 ── ECU
```

- `ssm.zig` — SSM2 packet framing and builders
- `openport.zig` — OpenPort AT command/reply protocol
- `transport.zig` — transport interface + hardware-free mocks
- `serial.zig` — macOS termios serial transport
- `device.zig` — device state machine (sequence numbers, channels, raw frames)
- `session.zig` — SSM link (K-line / CAN open, send, request)
- `ipc.zig` — JSON-lines server
- `main.zig` — CLI

## License

TBD.
