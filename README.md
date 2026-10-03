# GeForce NOW Menu (`gfn-omarchy`)

Installable **Omarchy (Quattro)** plugin that aims to make GeForce NOW titles feel native in Omarchy: search from the menu, pick a game, land an Apps launcher, launch without hunting inside the GFN client.

> **Identity**
>
> | Field | Value | Status |
> |-------|-------|--------|
> | Manifest `id` | `matt-dance.gfn` | Provisional — may rename before first public release |
> | Display `name` | **GeForce NOW Menu** | Locked (user confirmed) |
> | Repo-oriented name | `gfn-omarchy` | Locked for this project |
>
> Display name stays **GeForce NOW Menu**. Before publishing widely you may still pick a permanent namespaced id (for example `io.github.<you>.gfn-omarchy`); if you do, update `manifest.json` `id`, QML summon strings, the sample menu `action`, desktop `X-Omarchy-Plugin`, and this README. Folder under `~/.config/omarchy/plugins/` must match the manifest `id`.

Status: **scaffold with Flatpak launch + v1 catalog search**. Search fetches/caches the public GraphQL apps list (`games.geforce.com/graphql`, US/`en_US`, TTL ~6h) and filters locally by title — this repo does **not** invent authenticated GFN search/library APIs. Offline / cache failure falls back to Diablo IV.

## Why `overlay` + `service`?

From Omarchy’s Quattro plugin model:

| Kind | Role in this plugin |
|------|---------------------|
| **`overlay`** | Fullscreen search UI (same pattern as built-in emoji / clipboard overlays). Summoned from a menu `action:` via `omarchy-shell shell summon`. |
| **`service`** | Headless singleton for add-to-Apps / Flatpak `--url-route` launch so the overlay stays UI-focused and helpers stay mounted (`keepLoaded: true`). |

`omarchy plugin add` only clones + validates + toggles enablement. It does **not** inject menu rows or write `.desktop` files — those are documented companion steps below.

Conventions / launch research (project agent-store notes): `docs/omarchy-plugin-guide.md`, `docs/project-context.md`, and **`docs/gfn-linux-launch.md`** (Flatpak `--url-route`, GraphQL catalog, Diablo IV cmsId/uuid).

## Prerequisites

On the Omarchy machine:

1. Omarchy with Quattro shell plugins (`omarchy-shell`).
2. **GeForce NOW installed and signed in** (Omarchy: Install › Gaming › NVIDIA GeForce NOW). This plugin does not install or log you into GFN.
3. Optional but useful: `update-desktop-database` for refreshing Apps after writing launchers.

## Install

Once this repository is public (or otherwise cloneable):

```bash
omarchy plugin add <git-url-to-this-repo> --enable
```

Review-first (lands disabled):

```bash
omarchy plugin add <git-url-to-this-repo>
# inspect ~/.config/omarchy/plugins/matt-dance.gfn/
omarchy plugin enable matt-dance.gfn
```

Manual / local checkout:

```bash
# from a clone of this repo:
cp -a . ~/.config/omarchy/plugins/matt-dance.gfn
omarchy-shell shell rescanPlugins
omarchy plugin enable matt-dance.gfn
```

Plugins run **unsandboxed** inside `omarchy-shell` as your user. Review code before enabling.

## Menu extension (required companion step)

`plugin add` **does not** merge menu JSONC. After `omarchy plugin add … --enable`, install the sample Games rows with the safe helper:

```bash
# From a clone, or from ~/.config/omarchy/plugins/matt-dance.gfn/
bash scripts/install-menu-extension.sh
# Preview only:
bash scripts/install-menu-extension.sh --dry-run
omarchy menu refresh
```

[`scripts/install-menu-extension.sh`](scripts/install-menu-extension.sh) merges [`extensions/omarchy-menu.jsonc`](extensions/omarchy-menu.jsonc) into `~/.config/omarchy/extensions/omarchy-menu.jsonc` inside a managed `BEGIN`/`END matt-dance.gfn` block. It is idempotent (updates the marked block, or skips if the keys are already present), never wipes other user rows, and writes a `*.bak.<timestamp>` backup before changing the file.

Manual merge still works: copy the sample keys by hand, keep the file valid JSONC (broken user JSONC silently drops **all** user extension rows), then `omarchy menu refresh`.

The sample action summons the overlay:

```bash
omarchy-shell shell summon matt-dance.gfn '{}'
```

## Catalog search (v1)

Public GraphQL catalog → disk cache → local title filter (no authenticated `searchQuery`).

| Path | Purpose |
|------|---------|
| [`scripts/gfn-catalog-search.py`](scripts/gfn-catalog-search.py) | Paginate `https://games.geforce.com/graphql`, cache under `$XDG_CACHE_HOME/matt-dance.gfn/` (TTL ~6h), filter by title |
| `Service.qml` → `search()` | Runs the helper via Quickshell `Process`; Overlay watches `lastResults` |
| Offline fallback | Diablo IV row if network and cache both fail |

```bash
# From a checkout (or the installed plugin dir):
python3 scripts/gfn-catalog-search.py "Diablo IV"
# → JSON array: [{id, cmsId, title, shortName}, ...]
# Cache file: ${XDG_CACHE_HOME:-$HOME/.cache}/matt-dance.gfn/apps-US-en_US.json
# Force refetch:  python3 scripts/gfn-catalog-search.py "Diablo IV" --refresh
```

`shortName` may be `""` in catalog rows; write/launch still default to `game_gfn_pc`.

## Apps / `.desktop` launchers (RetroArch pattern)

Omarchy has no first-party per-game library provider. “Native” titles typically appear via the built-in **`apps`** provider (desktop entries), same idea as Install › Gaming › RetroArch Game Launcher.

This plugin ships:

| Path | Purpose |
|------|---------|
| [`scripts/write-desktop-entry.sh`](scripts/write-desktop-entry.sh) | Writes `~/.local/share/applications/gfn-<parent-game-id>.desktop` with Flatpak `--url-route` `Exec=` |
| [`desktop/gfn-example.desktop.example`](desktop/gfn-example.desktop.example) | Diablo IV example entry (not installed automatically) |

Launch pattern (from research `docs/gfn-linux-launch.md`):

```bash
flatpak run --command=/app/cef/GeForceNOW com.nvidia.geforcenow \
  '--url-route=#?cmsId=<CMS_ID>&launchSource=External&shortName=<SHORT_NAME>&parentGameId=<UUID>'
```

When catalog `shortName` is empty, the writer defaults to `game_gfn_pc` (Klay convention).

### Diablo IV example (catalog snapshot 2026-10-01 — re-verify before shipping)

| Field | Value |
|-------|--------|
| Title | Diablo IV |
| `cmsId` | `101069911` |
| `parentGameId` / `id` | `d32c9410-62cb-45cf-9c53-740bb92d4a2d` |
| `shortName` (fallback) | `game_gfn_pc` |

```bash
bash scripts/write-desktop-entry.sh \
  --cms-id 101069911 \
  --parent-game-id d32c9410-62cb-45cf-9c53-740bb92d4a2d \
  --title "Diablo IV"
```

Resulting `Exec=` (also in the example `.desktop`):

```text
flatpak run --command=/app/cef/GeForceNOW com.nvidia.geforcenow '--url-route=#?cmsId=101069911&launchSource=External&shortName=game_gfn_pc&parentGameId=d32c9410-62cb-45cf-9c53-740bb92d4a2d'
```

Desktop keys `X-GFN-CmsId`, `X-GFN-ParentGameId`, and `X-GFN-ShortName` carry the same ids for tooling.

## Validate

On an Omarchy host:

```bash
PLUGIN_DIR="$HOME/.config/omarchy/plugins/matt-dance.gfn"
omarchy plugin validate "$PLUGIN_DIR"
# optional, if qmllint + OMARCHY_PATH are available:
qmllint -I "$OMARCHY_PATH/shell" \
  "$PLUGIN_DIR/Overlay.qml" "$PLUGIN_DIR/Service.qml"
```

Rules worth knowing: namespaced non-`omarchy.*` id, every kind has an entry point file, **no symlinks** in the plugin tree.

## What works vs next

| Capability | Status |
|------------|--------|
| Root `manifest.json` (`schemaVersion` 1, `overlay` + `service`) | Works (layout) |
| Minimal QML entry points (`Overlay.qml`, `Service.qml`) | Works (UI + IPC shape); needs Omarchy host to run |
| Sample menu extension snippet | Works as copy/merge source — not auto-applied |
| Menu extension install helper | Works — `scripts/install-menu-extension.sh` (managed BEGIN/END, backup, dry-run) |
| `.desktop` writer script | Works — Flatpak `--url-route` `Exec=` + `X-GFN-*` keys |
| Diablo IV launch ids | Wired (`cmsId` `101069911`, uuid above) — re-verify on Omarchy |
| GFN catalog search | **Works** — `scripts/gfn-catalog-search.py` (GraphQL cache + local filter); Diablo IV offline fallback |
| Auto-merge menu on `plugin add` | **Not supported** by Omarchy — use the install helper (or merge by hand) |

## Renaming the plugin id

Display `name` stays **GeForce NOW Menu**. If you rename only the `id`:

1. Change `id` in [`manifest.json`](manifest.json) — leave `name` as `GeForce NOW Menu`.
2. Update summon strings in `Overlay.qml`, `Service.qml` fallbacks, and `extensions/omarchy-menu.jsonc`.
3. Update `X-Omarchy-Plugin` in the writer script / example desktop file.
4. If already installed: `omarchy plugin remove matt-dance.gfn`, then add again under the new id (folder name must match).
5. Re-merge menu action to summon the new id.

## Remove

```bash
omarchy plugin remove matt-dance.gfn
```

Also remove any Games rows (or the `BEGIN`/`END matt-dance.gfn` managed block) from `~/.config/omarchy/extensions/omarchy-menu.jsonc`, and any `~/.local/share/applications/gfn-*.desktop` files you no longer want.

## Layout

```text
.
├── manifest.json
├── Overlay.qml              # overlay entry point (search UI)
├── Service.qml              # service entry point (add / --url-route launch)
├── GfnModel.js              # search/launch/writer helpers + Diablo IV fallback
├── extensions/
│   └── omarchy-menu.jsonc   # sample Games-adjacent menu rows
├── scripts/
│   ├── gfn-catalog-search.py       # GraphQL fetch/cache + title filter
│   ├── install-menu-extension.sh   # merge sample Games rows into user JSONC
│   └── write-desktop-entry.sh
├── desktop/
│   └── gfn-example.desktop.example   # Diablo IV --url-route example
├── LICENSE                  # MIT
└── README.md
```

Research notes for Flatpak launch + catalog live in the project agent store: `docs/gfn-linux-launch.md`.
## License

MIT — see [LICENSE](LICENSE).
