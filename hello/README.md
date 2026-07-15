# Hello

Minimal example bar widget: shows a configurable greeting followed by a clock
(`hello 18:52:04`), refreshed every second.

Exists as a template for new plugins in this repo — smallest possible
`plugin.toml` + `widget.luau` + translations layout that passes
`noctalia plugins lint`.

## Settings

- **Greeting** — text shown before the clock (default `hello`).
