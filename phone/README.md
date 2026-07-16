# Phone

Phone battery in the bar, via [KDE Connect](https://kdeconnect.kde.org/). Click
the widget to **ring** the phone (find it).

Shows the battery percentage of the first paired, reachable device with a phone
glyph; the tooltip names the device and marks charging with `+`. A low-battery
notification fires once per drain below the threshold.

Updates are **event-driven** — the KDE Connect daemon emits dbus signals on
battery and reachability changes, so the widget refreshes immediately; a 60s
poll is the fallback.

## Requirements

- `kdeconnect` installed on the PC (daemon + `kdeconnect-cli`), the KDE Connect
  app installed on the phone, and the two **paired over the same network** (Wi-Fi
  / LAN — not Bluetooth). KDE Connect works standalone; no KDE desktop needed.
- Phone and PC reachable on the same subnet. If pairing fails, open TCP+UDP
  `1714–1764` in any firewall.

## Settings

- **Show percentage** — battery percent next to the glyph (default on).
- **Ring on click** — left-click rings the phone (default on).
- **Low battery notification** — notify below the threshold (default on).
- **Low battery threshold (%)** — default 15.
- **Hide when phone absent** — hide the widget when no phone is reachable
  (default on).

## Left click action

The **Left click action** setting picks what clicking the widget does:

- **Ring the phone** (default) — makes the phone ring so you can find it.
- **Open phone files** — mounts the phone's storage (SFTP, read-write) and opens
  it in a file manager. Drag files out to pull, drag files in to push — both
  directions in one window.

The files action needs `sshfs` (the SFTP mount backend) and, on the phone, the
KDE Connect **"Filesystem expose"** plugin enabled with storage permission
granted. The mount lands at `/run/user/<uid>/<device>/`; the **Storage subpath**
setting picks which folder opens (Android primary storage is
`storage/emulated/0`).

## Note

Phone **notifications** are bridged into your system by the KDE Connect daemon
itself — they appear as normal desktop notifications without this widget.

