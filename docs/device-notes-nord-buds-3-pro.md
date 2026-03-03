# Device Notes: OnePlus Nord Buds 3 Pro

This page captures device-specific behavior that we learned from real-world testing.

## ANC modes (user-facing)

- **ANC On**
- **Transparency**
- **Off**

## Important: “Set” bytes vs “Push” bytes

These buds may use different byte values depending on whether the state came from:

- a Mac/phone **SET** command (we send a command)
- an earbud gesture **PUSH** notification (buds stream status)

So we treat them separately:

### A) What the Mac sends (SET)

When you tap buttons in the app:

- Tap **ANC** → buds switch to ANC On
- Tap **Trans** → buds switch to Transparency
- Tap **Off** → buds switch to Off

### B) What the buds send (PUSH notifications)

When you long-press on the buds, many sessions only cycle between:

- ANC On
- Transparency

Off may appear only via the phone app / Mac app.

## Why “Off” sometimes doesn’t show up from gestures

Some firmwares simply don’t include “Off” in the gesture cycle, or they treat it differently depending on settings (phone app configuration, fit detection, etc).

This is not a bug in the Mac UI — it’s the device behavior.

