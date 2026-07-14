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
location = "~/Documents/git/noctalia-plugins"

[plugins]
enabled = ["mcs/hello"]
```

Path sources are scanned in place; `.luau` edits hot-reload via file watch.

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

## Lint

```
noctalia plugins lint <author>/<plugin>
```

Checks `getConfig` keys against declared settings and that entry files exist.
