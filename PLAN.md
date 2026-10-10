# Plan

Status: built. Plugin id `matt-dance.gfn-omarchy`, display name GeForce NOW Menu. The notes below are the original design. What shipped differs in a few places: search and add are the overlay, not a `gum` `gfn-add`; menu and desktop labels are `GFN - <Game Name>` with the store as the subtitle; remove is multi-select; desktop files are `gfn-<cmsId>.desktop`; launch is `scripts/gfn-play.sh`.

## Product

```
Gaming
  GeForce NOW
    Add a game
    Diablo IV
    Remove a game
```

Install > Gaming stays the installer list. Each added game also gets a `.desktop` file so the Apps grid shows it. The menu row and the Apps icon run the same launcher.

## Phase 1 — on this machine

1. One shared `gfn-play` that takes cmsId and parentGameId and runs the proven CEF command from `HANDOFF.md`. If a `GeForceNOW` window is already open, print that GeForce NOW has to be closed first and exit. Detect the window with `hyprctl clients` (class `GeForceNOW`). Do not use `pgrep -f` / `pkill -f` with the string GeForceNOW. Do not kill the existing process.
2. `gfn-add`, launched by `omarchy-launch-floating-terminal-with-presentation`:
   - `gum` input for the search string.
   - GraphQL search from `HANDOFF.md`. Discover `vpcId` from the last GeForce NOW session. Fall back to asking, with `NP-LAX-03` only as a known-good example.
   - `gum` choose for the title, then for a variant whose `gfn.status` is available. Label the store step as "Which store is your copy on?"
   - Download `GAME_BOX_ART`, resize to a PNG icon under `~/.local/share/icons/gfn/`.
   - Write `~/.local/share/applications/gfn-<slug>.desktop` (Name, GenericName, Comment including the store, Exec of `gfn-play`, Icon, `StartupWMClass=GeForceNOW`, `Categories=Game;`, Keywords from the title and store).
   - Record the game in a catalog JSON the menu writer owns.
3. `gfn-remove`: `gum` choose, delete that desktop file, icon, and catalog row, then rewrite the menu block.
4. Menu writer. `~/.config/omarchy/extensions/omarchy-menu.jsonc` is JSONC and is currently only a comment template that starts with `{` and ends with `}`. Insert the stable rows once. Rewrite only a marked block for generated games so later edits to the rest of the file survive.

```jsonc
"gaming": {"icon":"","label":"Gaming"},
"gaming.geforce-now": {"icon":"󰢹","label":"GeForce NOW"},
"gaming.geforce-now.add": {"icon":"","label":"Add a game","action":"omarchy-launch-floating-terminal-with-presentation gfn-add"},
// gfn-games:start
"gaming.geforce-now.diablo-iv": {"icon":"","label":"Diablo IV","description":"Steam","action":"gtk-launch gfn-diablo-iv.desktop"},
// gfn-games:end
"gaming.geforce-now.remove": {"icon":"","label":"Remove a game","action":"omarchy-launch-floating-terminal-with-presentation gfn-remove"}
```

The menu executes `action` via `Quickshell.execDetached`. `gtk-launch` matches what AppLibrary does. Prefer that over a second copy of the flatpak command in the JSON.

5. Adopt the existing Diablo IV entry into the catalog. Point its desktop file at `gfn-play` with the Steam ids. Keep the current icon. Fix Keywords so they say steam, not battlenet. Leave the file in `~/.local/share/applications/` so the Apps grid entry does not disappear.
6. Verify by reading the menu file back, running `desktop-file-validate` if it is installed, and doing one cold-start launch only if the user says GeForce NOW is closed. Do not kill a running stream to test.

## Phase 2 — downloadable plugin

After phase 1 feels right, put the scripts in a git repo:

- `manifest.json` with a plugin id and kind `service`, so `omarchy plugin add <url> --enable` is the download path the user asked for (Setup > Plugins > Add Plugin).
- The scripts live in the plugin directory. Menu actions call them by the installed path under `~/.config/omarchy/plugins/<id>/`.
- First enable inserts the Gaming section if it is missing. It must not rewrite user edits outside the marked game block, and it must not rewrite that block on every shell start.
- Document that plugins run unsandboxed inside `omarchy-shell`.

Do not edit `/usr/share/omarchy`. Do not patch the flatpak.

## Out of scope unless the user asks

- Fullscreen or workspace rules for class `^GeForceNOW$`. If added later, they go in `~/.config/hypr`.
- Checking library ownership before launch. The catalog does not know this account's licenses.
- WoW, Battle.net, Proton, or an FPS overlay.
- Reboot, NVIDIA reset, or any change to `battlenet-nvidia.sh`.
