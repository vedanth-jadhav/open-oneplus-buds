# Buds (macOS Menu Bar App)

This repo now contains a native macOS 26+ menu bar app (SwiftUI + CoreBluetooth) that controls OPOv1 earbuds using the same proven packet flow as `nordbuds.swift`.

Docs:

- `docs/README.md`

## What You Get

- Menu bar item: ANC icon + battery text like `82%` (low battery shows `!`)
- Rich popover UI with Liquid Glass styling
- Inline command progress (no notification banners)
- Robust BLE behavior:
  - Writes to `0100079A-...` using `.withoutResponse`
  - Subscribes to safe notify characteristics for live updates (vendor `0200079A-...` plus other non-encrypted notifies)
  - Auth flow `HELLO -> REGISTER` before queries/sets
  - Serialized command queue (one operation at a time) with timeout + retry
  - Auto-reconnect (backoff), **no polling**

## No Polling (by design)

- No repeating “query every X seconds” timers.
- Battery/ANC queries are **one-shot**:
  - on popover open (only if needed)
  - on explicit user actions (Refresh / Set ANC)
- “Live updates” (BLE notifications) are enabled only while the popover is open to reduce earbud battery impact.

## Icons

Put your icons in:

`Sources/BudsApp/Resources/Icons/`

Expected filenames (pdf or png):
- `anc_on.pdf` / `anc_on.png`
- `anc_trans.pdf` / `anc_trans.png`
- `anc_off.pdf` / `anc_off.png`

The app will fall back to SF Symbols if these aren’t present.

## App Icon (Finder / Login Items)

Generate a clean local `Assets/Buds.icns`:

```bash
./scripts/make_app_icon.sh
```

## CLI Workflow

Build:

```bash
make build
```

Self-test (no XCTest required):

```bash
make test
```

Bundle an unsigned local app:

```bash
./scripts/bundle.sh debug
open dist/Buds.app
```

Package (app + zip + dmg) and strip quarantine:

```bash
make package
```

Install to `~/Applications`:

```bash
make install
open ~/Applications/Buds.app
```

Run (bundle + open):

```bash
make run
```

## Debug logs

Run the app with terminal logs enabled:

```bash
cd cracked-oneplus-buds
BUDS_DEBUG=1 ./scripts/run.sh
```

## Bluetooth permission (prompt should be once)

If macOS keeps prompting for Bluetooth permission after rebuilds, it’s usually because the app is unsigned/ad-hoc signed and macOS treats each build as a new identity.

Use:

```bash
make install
```

and if you have a signing identity, optionally:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make install
```

If you don’t have any signing identities, create a local Code Signing certificate in Keychain Access (see `docs/debugging.md`) and use it:

```bash
CODESIGN_IDENTITY="Buds Local" make install
```

## Notes

- This uses SwiftPM and CLI tools only (no Xcode.app / no xcodebuild).
- If macOS blocks launching the local build due to quarantine, remove the attribute:

```bash
xattr -dr com.apple.quarantine dist/Buds.app
```
