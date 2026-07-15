# WiFi

WiFi-only bar widget — unlike the built-in Network widget it never shows wired
interfaces (no `enp5s0` in your bar), only the wireless state:

- signal-strength glyph (`wifi-0` … `wifi`, same bands as the built-in)
- SSID and/or signal percent next to the glyph (both optional)
- `wifi-off` when the radio is disabled, `wifi-question` when on but not connected
- notification on connect/disconnect (startup state never notifies)
- left click: control center network section; right click: toggle the radio

Event-driven via `nmcli monitor` — connect/disconnect renders within a second;
a 30s refresh keeps the signal level current. Requires NetworkManager (`nmcli`).

## Settings

- **Show SSID** — network name next to the glyph (default on)
- **Show signal strength** — percentage next to the glyph (default off)
- **Notify on connect/disconnect** — default on
- **Hide when WiFi is off** — remove the widget while the radio is disabled
