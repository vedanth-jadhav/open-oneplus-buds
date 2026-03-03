# Debugging (Logs, What to Look For)

## Run with logs

Use:

```bash
cd cracked-oneplus-buds
BUDS_DEBUG=1 ./scripts/run.sh
```

Important:

- When `BUDS_DEBUG=1`, the script runs the app **in the terminal** so your environment variables apply and logs print.
- If you open the app via Finder, environment variables usually won’t apply.

## “Why does macOS ask for Bluetooth permission again?”

macOS stores privacy permissions (like Bluetooth) based on the app’s identity.

If you rebuild frequently and run an **unsigned or ad-hoc signed** app, macOS may treat each build as “new” and prompt again.

Best practice for “ask once”:

1) Install the app to `~/Applications`:

```bash
make install
```

2) Use a stable code signing identity if you have one:

- The build scripts will automatically prefer an `Apple Development:` identity if it exists.
- Or force one explicitly:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make install
```

If you don’t have a signing identity, macOS may still re-prompt across rebuilds. That’s a system policy, not an app bug.

### Create a local signing identity (no Xcode required)

Fastest path:

1) Open **Keychain Access**
2) Menu: **Keychain Access → Certificate Assistant → Create a Certificate…**
3) Use:
   - Name: `Buds Local`
   - Identity Type: **Self Signed Root**
   - Certificate Type: **Code Signing**
4) Then run:

```bash
CODESIGN_IDENTITY="Buds Local" make install
```

This gives macOS a stable identity for the app, so the Bluetooth permission prompt is much more likely to be “once”.

## What logs mean (high-level)

### Live Updates toggles

- You should see something like:
  - `setLiveUpdatesEnabled(on)` when popover opens
  - `setLiveUpdatesEnabled(off)` when popover closes (after a short delay)

### Notifications

- `Notify state ok (...) isNotifying=y` means we are subscribed and listening.
- `isNotifying=n` means we are unsubscribed (buds may stop streaming).

### Traffic

- `[TX] ...` are packets we send (HELLO/REGISTER/queries/sets)
- `[RX] ...` are packets we receive

If popover is open and you see **no RX at all**, you’re likely not receiving notifications.

## Common symptoms

### “ANC changed on the buds but app didn’t update”

Possible reasons:

- Live Updates were OFF (popover closed, or unsubscribed)
- Buds firmware didn’t push that change over BLE notifications in that session
- The buds push the change, but it’s a frame shape we’re not mapping yet

If you want help, paste the RX frames that arrive right after you long-press ANC.
