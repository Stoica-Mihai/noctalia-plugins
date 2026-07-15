# Weather Wallpaper

Your wallpaper follows the weather outside. Rain on the window, rain on the
desktop.

Reads noctalia's **own weather cache** (`~/.cache/noctalia/weather.json`) — no
extra API calls, no location setting; it uses the location your weather widget
already has. Requires weather to be enabled in noctalia.

## Setup

Create one folder per condition under the wallpapers folder (default
`~/Pictures/weather-wallpapers`) and drop images in (jpg/jpeg/png/webp):

```
weather-wallpapers/
  clear-day/
  clear-night/
  cloudy/
  fog/
  rain/
  snow/
  storm/
  default/        # fallback for conditions you have no images for
```

Only conditions you care about need folders — anything missing falls back to
`default/`, and if that is empty too the wallpaper is left alone.

A random image from the matching folder is applied when the condition changes.
The wallpaper is otherwise never touched (enable "Rotate within condition" to
re-roll on every check).

## Condition mapping (WMO weather codes)

| Folder | Codes |
|---|---|
| `clear-day` / `clear-night` | 0, 1 (by day/night) |
| `cloudy` | 2, 3 |
| `fog` | 45, 48 |
| `rain` | 51–67, 80–82 |
| `snow` | 71–77, 85, 86 |
| `storm` | 95+ |

## Note

Disable noctalia's own wallpaper rotation if you use this — they will fight.
