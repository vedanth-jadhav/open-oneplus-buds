# Device Notes: OnePlus Buds Z2

Reverse-engineering notes and protocol details for the OnePlus Buds Z2 (Model E504A / OPOv1 family). Research conducted with Google Antigravity.

## GATT services and characteristics

Unlike Nord models that use custom 128-bit UUIDs (`0000079A-D102-11E1-9B23-00025B00A5A5`), the OnePlus Buds Z2 exposes its control channel under 16-bit based 128-bit UUIDs alongside Fast Pair (`FE2C`):

| Entity | UUID | Properties | Purpose |
| :--- | :--- | :--- | :--- |
| Command service | `000008A4-0000-1000-8000-00805F9B34FB` | None | Primary OPOv1 channel |
| Write characteristic | `00000001-0000-1000-8000-00805F9B34FB` | Write without response (`0x04`) | Send packets (`HELLO`, `REGISTER`, `SET`, `QUERY`) |
| Notify characteristic | `00000002-0000-1000-8000-00805F9B34FB` | Notify (`0x10`) | Receive responses and push telemetry |
| Telemetry service | `FE2C` | Fast Pair / GATT | Used for `retrieveConnectedPeripherals` |

When connected to macOS, calling `central.retrieveConnectedPeripherals(withServices: [CBUUID("FE2C"), CBUUID("000008A4...")])` finds the peripheral directly without an active scan.

## Authentication handshake

The earbuds require the standard handshake before accepting commands:

1. `HELLO`: `AA 07 00 00 00 01 23 00 00 12`
   - Ack: `AA 0D 00 00 00 81 23 ...`
2. `REGISTER`: `AA 0C 00 00 00 85 41 05 00 00 B5 50 A0 69` (Token: `B5 50 A0 69`)

## ANC modes and wire values

The OnePlus Buds Z2 firmware defines these states:

| Mode | Wire byte | Packet tail | Notes |
| :--- | :---: | :--- | :--- |
| Off | `0x01` | `... 01 01 01` | Passthrough, no noise control |
| Transparency | `0x02` | `... 01 01 02` | Ambient sound |
| Noise cancellation | `0x04` | `... 01 01 04` | Normal noise cancellation |
| Max noise cancellation | `0x08` | `... 01 01 08` | Max noise cancellation |

### Push notifications and gestures

When cycling modes using touch-and-hold gestures configured in HeyMelody:

- Transparency reports `AA 0B 00 00 04 02 <seq> 04 00 03 01 01 02`
- Max noise cancellation reports `AA 0B 00 00 04 02 <seq> 04 00 03 01 01 08`
- Normal noise cancellation reports `AA 0B 00 00 04 02 <seq> 04 00 03 01 01 04`
- Writing `0x08` to `00000001` activates max noise cancellation and returns `AA 08 00 00 04 84 42 01 00 00`.

### Multi-frame packet concatenation

On connection or mode switch, the earbuds often pack two frames into a single BLE notification:

```text
AA 0B 00 00 04 02 24 04 00 03 01 01 08 AA 0B 00 00 04 02 25 04 00 03 02 01 0A
```

The first frame (`... 01 01 08`) contains the ANC mode. The second frame contains volume or telemetry. Parsers should inspect each `0xAA` subframe rather than inspecting only the end of the byte buffer.

## Battery responses and case telemetry

Battery query responses arrive under `CAT=0x06 SUB=0x81 CMD=0x25`:

```text
AA 0B 00 00 06 81 25 04 00 00 <pairCount> <id> <percent>
```

When only one bud reports:
- Example: `AA 0B 00 00 06 81 25 04 00 00 01 01 5A`
- `pairCount = 0x01`, `id = 0x01` (left bud), `percent = 0x5A` (90%)
- Parsers should check `bytes.count >= 11` rather than requiring multiple pairs.

The charging case communicates via the earbuds. It does not maintain an independent BLE link to the Mac. Case battery percentage updates arrive via `CAT=0x04 SUB=0x02` telemetry when the lid opens or closes, or when a bud is placed in the case:

```text
AA 0D 00 00 04 02 <seq> 07 00 01 02 01 <casePercent> 02 <budPercent>
```
