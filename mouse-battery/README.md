# Mouse Battery

Bar widget showing the battery level of a Keychron wireless mouse (M6 8K /
Ultra-Link 8K dongle, VID `0x3434`), read directly over raw HID. Standalone —
no companion app required.

## How it works

The widget runs the bundled `battery.py` (pure Python stdlib) on a configurable
interval. The script scans `/sys/class/hidraw` for the Keychron config
collection (usage page `0xFFC1`), sends a settings-block read (`0xB3 0x06`),
and parses the battery byte from the reply: low 7 bits = percent, high bit =
charging.

The widget hides itself when no mouse answers (dongle unplugged / asleep).

## Requirements

- `python3` (stdlib only)
- Read/write access to the hidraw node. Without a rule that grants it, add:

  ```
  # /etc/udev/rules.d/70-keychron-mouse.rules
  KERNEL=="hidraw*", ATTRS{idVendor}=="3434", MODE="0660", TAG+="uaccess"
  ```

  then `sudo udevadm control --reload && sudo udevadm trigger` and replug.

## Settings

- **Poll interval (seconds)** — how often the battery is read (default 60).
- **Show percentage** — numeric percent next to the battery glyph (default on).

## Credits

Protocol reverse-engineered in [squeak](https://github.com/Stoica-Mihai/squeak),
a full Keychron mouse configurator for Linux.
