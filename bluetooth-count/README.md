# Bluetooth Count

Bluetooth bar widget with an **always-visible connected-device count** next to
the glyph — no hovering needed. The built-in widget only switches to a subtle
`bluetooth-connected` glyph and puts details in the tooltip; this one puts the
number on the bar.

- `bluetooth-off` glyph when the adapter is powered off
- `bluetooth` glyph when on with nothing connected (count hidden unless
  "Show zero" is enabled)
- `bluetooth-connected` glyph + count when devices are connected
- Tooltip lists connected device names
- Left click: opens the control center Bluetooth section
- Right click: toggles adapter power

Event-driven: a `bluetoothctl --monitor` stream triggers an immediate state
refresh on connect/disconnect/power events — no periodic polling (a 60s
fallback re-check runs only as a safety net if the stream dies). Requires
`bluetoothctl` (part of bluez).

## Settings

- **Show zero** — show `0` instead of hiding the count when nothing is connected
- **Hide when Bluetooth is off** — remove the widget entirely while powered off
