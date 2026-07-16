# Battery Monitor

One bar widget for every peripheral battery. Merges two sources:

- **upower devices** — game controllers, Bluetooth headsets/keyboards, and
  anything else with a battery that the kernel exposes to upower.
- **Keychron mouse over raw HID** — read via the bundled `battery.py`, because
  the mouse's proprietary protocol is invisible to upower.

Shows the **lowest** battery by default; **scroll** over the widget to cycle
through devices. The tooltip lists every device with its level and a `+` when
charging.

Updates are **event-driven** via `upower --monitor` — devices connecting and
disconnecting reflect immediately, not on the next poll. The poll interval is a
fallback and keeps the (non-upower) Keychron mouse reading fresh.

Low-battery notifications are **per device** and **persist across restarts**
(state stored under `pluginDataDir()`), so you get notified once per drain, not
on every reload.

## Requirements

- `upower` for standard peripherals (game controllers, BT audio, …)
- `python3` + hidraw access for the Keychron mouse source. Without
  [squeak](https://github.com/Stoica-Mihai/squeak) installed, add a udev rule:

  ```
  # /etc/udev/rules.d/70-keychron-mouse.rules
  KERNEL=="hidraw*", ATTRS{idVendor}=="3434", MODE="0660", TAG+="uaccess"
  ```

  then `sudo udevadm control --reload && sudo udevadm trigger` and replug.

Neither is strictly required — the widget shows whatever it can find, and hides
itself when nothing reports a battery.

## Settings

- **Poll interval (seconds)** — how often batteries are read (default 60).
- **Show percentage** — numeric percent next to the glyph (default on).
- **Low battery notification** — notify when a device drops below the threshold
  (per device, once per drain, persisted).
- **Low battery threshold (%)** — default 20.

