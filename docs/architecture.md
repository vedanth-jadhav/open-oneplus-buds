# Architecture (No-Polling, Event-Driven)

The app has one job: let you control and view your buds (ANC + battery) from a **macOS menu bar popover**.

The key design rule is:

> **No polling.**  
> The app does *not* run repeating timers that keep querying the buds.

Instead, it’s **event-driven**:

- The buds can **push updates** over BLE notifications (when we’re listening)
- The app sends **one-shot commands** only when you open the popover or tap a button

---

## Components

### UI layer (Menu bar + Popover)

- Shows current state (Connected?, ANC mode, battery)
- Sends user intents (Set ANC, Refresh battery, Reconnect)
- Enables/disables “Live Updates” depending on whether the popover is open

### Bluetooth layer (Buds Client)

- Owns the BLE connection to the buds
- Subscribes/unsubscribes to notifications (“live updates”)
- Performs the one-time handshake (HELLO → REGISTER) when needed
- Parses incoming frames and publishes state updates to the UI

---

## Component Diagram

```mermaid
graph LR
  subgraph UI["UI Layer (SwiftUI)"]
    MenuBar["Menu Bar Label"] --> Model["App Model"]
    Popover["Popover UI"] --> Model
  end

  subgraph Core["Core Layer (BudsCore)"]
    Model --> Client["Buds Client"]
    Client --> BLE["CoreBluetooth"]
    BLE --> Buds["Earbuds"]
    Buds --> BLE
    BLE --> Client
    Client --> Model
  end
```

---

## Data Flow (Event-Driven)

```mermaid
flowchart TD
  RX["BLE Notification (RX bytes)"] --> Parse["Parse protocol frames"]
  Parse --> State["Update cached state (ANC / Battery)"]
  State --> Emit["Emit event stream update"]
  Emit --> Model["App Model receives event"]
  Model --> UI["SwiftUI re-renders"]
```

---

## Key UX / Battery Tradeoff

**Live updates only when the popover is open**:

- Popover open = subscribe to notifications = very responsive + can mirror earbud gestures
- Popover closed = unsubscribe = minimal BLE traffic + lower earbud battery impact

That means the menu bar can occasionally be “stale” while the popover is closed — by design.

