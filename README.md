# noctalia-plugins

Personal plugin source for [Noctalia v5](https://github.com/noctalia-dev/noctalia).

## Layout

```
catalog.toml            # source catalog: one [[plugin]] row per plugin
<plugin>/               # plugin id "<author>/<plugin>" lives at "<plugin>/" by convention
  plugin.toml           # manifest: id, name, min_noctalia + [[widget]]/[[panel]]/... entries
  *.luau                # entry scripts
  translations/en.json  # strings for label_key / description_key
```

## Use as a path source (live dev)

In a `*.toml` under `~/.config/noctalia/`:

```toml
[[plugins.source]]
kind = "path"
name = "dev"
location = "/home/you/path/to/noctalia-plugins"

[plugins]
enabled = ["mcs/wifi"]
```

Path sources are scanned in place; `.luau` edits hot-reload via file watch.
Use an absolute location — with `~` the plugin store never loads READMEs or
thumbnails (shell bug: the file cache skips tilde expansion).

## Use as a git source

Commit changes, then point a source at the repo (any git URL works, including a local path):

```toml
[[plugins.source]]
kind = "git"
name = "mine"
location = "https://github.com/Stoica-Mihai/noctalia-plugins"
```

Git sources are cloned bloblessly into `~/.local/state/noctalia/plugins/sources/<name>/repo`
and enabled plugins are exported to `.../plugins/materialized/<name>/`.
Update with `noctalia msg plugins update <name>` or `auto_update = true` (6h tick).

## Plugins

- **`mcs/bluetooth-count`** — Bluetooth glyph with an always-visible
  connected-device count, event-driven via `bluetoothctl --monitor`, with
  connect/disconnect notifications.
- **`mcs/wifi`** — WiFi-only indicator: signal-band glyph, SSID, notifications;
  never shows wired interfaces. Requires NetworkManager.
- **`mcs/phone`** — phone battery in the bar via KDE Connect; left click rings
  the phone or opens its files (setting). Event-driven over dbus. Requires
  `kdeconnect` + phone app paired over LAN; the files action needs `sshfs`.
- **`mcs/battery-monitor`** — Battery Monitor: one widget aggregating every
  peripheral battery. Merges upower devices (controllers, BT headsets/keyboards)
  with a Keychron mouse read over raw HID (VID `0x3434`) via a bundled pure-stdlib
  `battery.py`. Scroll to cycle devices; per-device low-battery notifications
  persist across restarts. The mouse source needs `python3` + hidraw access —
  without [squeak](https://github.com/Stoica-Mihai/squeak) installed, add a udev rule:

  ```
  # /etc/udev/rules.d/70-keychron-mouse.rules
  KERNEL=="hidraw*", ATTRS{idVendor}=="3434", MODE="0660", TAG+="uaccess"
  ```

  then `sudo udevadm control --reload && sudo udevadm trigger` and replug.
- **`mcs/nethome`** — Midea AC (NetHome Plus generation, V2 LAN protocol):
  indoor temp + running state in the bar, left click opens a control panel
  (power, mode, target temperature). Pure-LAN via broadcast discovery — no
  cloud account. Requires `msmart-ng` (`uv tool install msmart-ng`).

## Lint

```
noctalia plugins lint <author>/<plugin>
```

Checks `getConfig` keys against declared settings and that entry files exist.
