# Docs

This folder explains how the macOS menu bar app works **without polling**, and how it uses **BLE notifications** (live updates) in a way that’s friendly to your earbuds’ battery.

## Attribution / Credits

This project is possible because **Aasheesh** reverse engineered the OnePlus/OPOv1 protocol and published the original work (blog + reference implementation).

- Original repo (protocol cracking / CLI groundwork): https://github.com/AasheeshLikePanner/cracked-oneplus-buds
- Reverse engineering write-up: https://aasheesh.vercel.app/blog/oneplus-buds

The **macOS menu bar app** and ongoing app-level development in this repository is done by **Vedanth**.

Start here:

- `architecture.md` — what the app is made of, and how data flows
- `no-polling.md` — what we mean by “no polling” + what triggers BLE traffic
- `notifications-and-live-updates.md` — how/when the buds stream updates to the Mac
- `battery-impact.md` — battery-drain reality + how we minimize it
- `debugging.md` — how to run with logs + what to look for
- `device-notes-nord-buds-3-pro.md` — your specific device mappings/quirks
