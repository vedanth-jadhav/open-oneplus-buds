# Battery Impact (Reality + Mitigation)

## What can drain earbud battery (in this setup)

Earbuds are tiny. BLE is low-power, but it still costs energy when:

- The buds keep their radio active to send notifications
- The Mac is subscribed, and the buds decide to stream telemetry frequently
- The Mac sends lots of commands (queries/sets) repeatedly

## The strategy we use

### 1) No polling
No repeating “query every X seconds/minutes” timers.

### 2) Popover-only live updates
We only subscribe to notifications while you’re actively looking at the popover.

That’s the biggest battery-friendly choice.

## What this means for UX

- When popover is open: best experience, live changes, fast updates
- When popover is closed: quieter, less battery impact, but UI may not instantly reflect earbud gesture changes

## How to measure (simple A/B test)

Do this if you want proof:

1) Charge buds to a known level (e.g., L/R ~80%)
2) Pick a time window (30–60 minutes)
3) Compare two runs:
   - **Run A:** Buds app running, but popover kept closed
   - **Run B:** Buds app not running at all

If A ≈ B, then our “popover-only live updates” is doing its job.

Optional third run:
   - **Run C:** Keep popover open for the whole window (expect more traffic + potentially more drain)

## Using logs as a proxy

When debug logs are enabled, the app reports how chatty the connection was while Live Updates were ON:

- packets / second
- bytes / second

More packets/sec generally means more radio activity.

