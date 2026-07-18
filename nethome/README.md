# NetHome AC

Midea AC (paired in the NetHome Plus Android app) in the noctalia bar:
indoor temperature + running state, left click opens a control panel with
power toggle, mode buttons (auto/cool/dry/heat/fan) and a target
temperature slider (16–32 °C).

## Requires

- `midea-beautiful-air-cli` and `msmart-ng` on PATH:
  `uv tool install midea-beautiful-air && uv tool install msmart-ng`
  (or the `pipx` equivalents). Discovery/status use the former; commands go
  through msmart-ng, which performs the capabilities handshake some devices
  require before accepting controls.
- The AC on the same LAN as this machine.

## How it works

First poll with account + password set runs a one-time cloud `discover`
(NetHome Plus login) and caches the device ip/token/key in
`~/.cache/noctalia-nethome/device.env`. Every poll and command after that
is a direct LAN exchange — no cloud. Changing account or password in the
widget settings invalidates the cache and re-discovers.

## Settings

- **NetHome Plus account / password** — login for the one-time discover.
  The password sits in plain text in the noctalia config.
- **Show indoor temperature** — bar text on/off.
- **Hide when AC absent** — hide vs. dimmed glyph when unreachable.
- **Poll interval** — LAN status poll cadence (10–300 s).
