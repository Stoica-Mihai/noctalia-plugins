# NetHome AC

Midea AC in the noctalia bar: indoor temperature + running state, left
click opens a control panel with power toggle, mode buttons
(auto/cool/dry/heat/fan) and a target temperature slider (16-32 °C).

Works with V2-protocol units (the NetHome Plus generation) — everything is
LAN-only via UDP broadcast discovery, no cloud account needed at all.

## Requires

- `msmart-ng` on PATH: `uv tool install msmart-ng` (or `pipx`)
- The AC on the same LAN as this machine.

## How it works

First poll broadcast-discovers the AC and caches its ip/id in
`~/.cache/noctalia-nethome/device.env`; every poll and command after that
is a direct LAN session. Commands perform the capabilities handshake the
device requires before it accepts controls. If the AC vanishes for long
(e.g. new DHCP lease), the cache is dropped and discovery re-runs on its
own.

The wifi module in these units handles one session at a time and wedges
under pressure — the widget keeps a hard floor between sessions and probes
reachability before declaring the device gone.

## Settings

- **Device name** — display name; empty uses the AC's network name.
- **Show indoor temperature** — bar text on/off.
- **Hide when AC absent** — hide vs. dimmed glyph when unreachable.
- **Poll interval** — LAN status poll cadence (30-600 s).
