# Handoff

Machine: mdance, Omarchy (Hyprland) on Linux. Home `/home/mdance`. Workspace this folder lives in: `/home/mdance/Work`.

The user likes GeForce NOW on Omarchy and wants a game in the launcher to open inside the GeForce NOW app, close to a native launch. Diablo IV was the trial. It worked. They then asked for a plugin: download it, add a Gaming menu option, search for a game, pick the store they own it on, and have that game appear in the Gaming menu. That design was agreed and saved. Implementation has not started.

An earlier question about an FPS overlay for WoW classic beta was dropped. Do not resume it.

## Conversation, in order

1. User asked if Omarchy has an FPS monitor for WoW classic beta. Unanswered. Out of scope now.
2. User asked to brainstorm an Omarchy plugin that adds a game from the launcher and opens it directly in GeForce NOW.
3. User said "Let's try Diablo 4." A desktop entry was created and a cold start streamed Diablo IV. They called that amazing.
4. User described the plugin: Download Plugin, a Gaming menu option, search, pick the store, game appears in the Gaming menu.
5. The design below was agreed. User went to bed and asked to save the plan.
6. User asked to move development to Cursor. This folder is that package.

## What shipped on this machine

Diablo IV is a normal app-menu entry. Name in the grid: Diablo IV. It uses the Steam variant because the last real GeForce NOW session on this machine was Steam (`cmsId` 102670811). Battle.net (`cmsId` 102348311) is the other available variant. The desktop file's Keywords still include `battlenet`. That is leftover and was not asked to be fixed.

Proven play command, in `~/.local/bin/gfn-play-diablo-iv`:

```bash
#!/usr/bin/env bash
nv_host="$(flatpak --gl-drivers 2>/dev/null | grep -Eo '^nvidia-[0-9-]+' | head -n 1)"
exec flatpak run --user \
  --command=/app/cef/GeForceNOW \
  --cwd=/app/cef \
  ${nv_host:+--env=NV_HOST_DRIVER_VERSION="$nv_host"} \
  ${nv_host:+--env=NV_FLATPAK_DRIVER_VERSION="$nv_host"} \
  com.nvidia.geforcenow \
  --url-route='#?cmsId=102670811&launchSource=External&shortName=&parentGameId=d32c9410-62cb-45cf-9c53-740bb92d4a2d'
```

Cold start on 2026-09-30 renamed the window to `Diablo® IV on GeForce NOW` and requested a stream. Window class is `GeForceNOW`. It was not fullscreen. A Hyprland rule for that was discussed and not applied.

## Why the launch looks like that

Official client: user Flatpak `com.nvidia.geforcenow`, version 2.0.88.129. Installed by Omarchy's `omarchy-install-gaming-geforce-now`. The menu entry the user already uses for the library is `~/.local/share/applications/com.nvidia.geforcenow.desktop`, whose Exec is the script `~/.local/share/applications/NVIDIA GeForce NOW`.

That script runs `flatpak run com.nvidia.geforcenow --no-relaunch` and does not forward other arguments. Inside the flatpak, `/app/bin/GeForceNOW` only reads `$1` for `--no-relaunch`, then runs `cd /app/cef; ./GeForceNOW` with no `"$@"`. A route passed the normal way never reaches the client. The first Diablo try opened the library for that reason. Do not patch the flatpak or that library launcher. Updates overwrite the flatpak, and the library launcher must keep working.

Direct launch is `flatpak run --user --command=/app/cef/GeForceNOW --cwd=/app/cef` plus `--url-route`. The CEF binary logs `Launched with URL route!`. The route format, reconstructed from the binary and matching the Windows shortcut payload:

```
--url-route='#?cmsId=<numeric>&launchSource=External&shortName=&parentGameId=<uuid>'
```

`shortName` from the catalog is often empty. Empty shortName plus cmsId and parentGameId worked. Skipping `/app/bin/GeForceNOW` also skips its update check. Pass `NV_HOST_DRIVER_VERSION` and `NV_FLATPAK_DRIVER_VERSION` from `flatpak --gl-drivers` (`nvidia-<version>`). On the boot that was tested, both were `nvidia-610-57-04`.

The packaged client has deeplink support and an in-app "Add desktop shortcut" (`Gfn.Streamer.AddDesktopShortcut` with streamer, parentGameId, cmsId, appName, shortName, iconUrl). The live session config set `showAddToDesktopShortcut` to false, so NVIDIA's own button is hidden. Build our own entries.

Cold start only. A second CEF process while GeForce NOW is already open logs the route and exits. The existing window stays on the current game. The future play script should notice a window of class `GeForceNOW` and tell the user to close it. Do not kill a running GeForce NOW or WoW session to "fix" a launch.

Startup noise that is not a failure: raster_decoder / SetBucket lines, a gamescope Vulkan layer warning, missing `libNvCamera.so`, a portal complaint about `LC_ALL`. Filter those when reading logs. Logs live at `~/.var/app/com.nvidia.geforcenow/.local/state/NVIDIA/GeForceNOW/console.log`.

## Catalog search that worked

`POST https://apps.gxn.nvidia.com/graphql` with header `nv-client-id: ec7e38d4-03af-4b58-b131-cfb0495903ab`. That client id is the public one in the flatpak file `mall/shared/assets/config/config.json` (lcars `clientId`). A request without the header returned 403.

```graphql
query ($vpcId: String!, $locale: String!, $searchString: String!) {
  apps(vpcId: $vpcId, language: $locale, searchQuery: $searchString, first: 12) {
    items {
      id
      title
      images { KEY_ART GAME_BOX_ART GAME_LOGO }
      variants { id appStore shortName storeUrl gfn { status } }
    }
  }
}
```

Variables that returned Diablo IV: `vpcId` `NP-LAX-03`, `locale` `en_US`, `searchString` `Diablo IV`. Search without `vpcId` returns 400: searchQuery must specify vpcId. Read `vpcId` from the last GeForce NOW session when possible. Do not hardcode `NP-LAX-03` forever.

Dead ends:

- `https://static.nvidiagrid.net/supported-public-game-list/gfnpc.json` returns HTTP 200 and body `null`.
- GFNDB's "GFN ID" for Diablo IV, `101069911`, is not a variant cmsId. `variantIds: [101069911]` returned an empty item list.
- Variant `id` in this API is the cmsId (a numeric string). Parent `id` is the UUID used as `parentGameId`.

Diablo IV record:

| Field | Value |
|---|---|
| Title | Diablo® IV |
| parentGameId | `d32c9410-62cb-45cf-9c53-740bb92d4a2d` |
| Battle.net cmsId | `102348311` (AVAILABLE) |
| Steam cmsId | `102670811` (AVAILABLE), Steam app 2344520 |
| Box art | `https://img.nvidiagrid.net/apps/d32c9410-62cb-45cf-9c53-740bb92d4a2d/ZZ/GAME_BOX_ART_01_9a4e5a3e-5d5c-4ca6-8df6-e2deb9eef382.jpg` (628x888) |

The installed icon is that box art resized with ImageMagick to 362x512 PNG at `~/.local/share/icons/gfn/diablo-iv.png`.

The store list is whatever variants the catalog returns. GeForce NOW still checks that the account owns that copy after launch. Do not scrape console.log for account ids (`userId`, `externalUserId`, `idpId`, `deviceId`).

## How Omarchy menus actually work

Two different surfaces:

- The app grid lists XDG desktop entries and launches them with `uwsm-app -- gtk-launch <id>.desktop` from `/usr/share/omarchy/shell/services/AppLibrary.qml`. Per-game `.desktop` files in `~/.local/share/applications/` are how a game shows up there.
- The Omarchy menu (the one with Install > Gaming) is JSONC. Defaults: `/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc`. User additions: `~/.config/omarchy/extensions/omarchy-menu.jsonc`. That user file is still the empty comment template. It hot-reloads on save. IDs are object keys. Dotted IDs build the tree (`gaming.geforce-now.add` appears under `gaming.geforce-now`). An entry with `action` is a command. An entry with no action is a submenu.

Install > Gaming (`install.gaming.*`) is a list of installers: Steam, RetroArch, Minecraft, NVIDIA GeForce NOW, Xbox Cloud, Xbox Controllers, Battle.net, Lutris, Heroic, RetroArch Game Launcher. Remove > Gaming mirrors it. Those rows are gated with `when`. Playable games need their own `gaming` section so they are not mixed into the installer list.

`omarchy plugin add <git-url> --enable` clones into `~/.config/omarchy/plugins/<id>/` and can enable a shell plugin. Setup > Plugins > Add Plugin already runs that. Plugins are bar widgets, overlays, panels, or services inside the long-running `omarchy-shell` process. They run unsandboxed. A manifest cannot declare menu rows. Menu providers are hardcoded in `/usr/share/omarchy/shell/plugins/menu/Menu.qml` to `fonts`, `power-profiles`, and a QML `apps` provider. Any other `provider` name in the user extension is ignored. Added games have to be static action rows rewritten from a catalog file.

`gum` plus `omarchy-launch-floating-terminal-with-presentation` is how existing Gaming installers ask questions. Use that for search, game pick, and store pick. An overlay plugin is optional later polish. It still needs the menu-extension write.

There is no post-enable hook that writes menu files. The plugin's one-time setup has to insert the Gaming section. After that, only a marked block of generated game rows should be rewritten.

Omarchy end-user rules, if Cursor can see them, are in `/home/mdance/.agents/skills/omarchy/SKILL.md` and `plugins.md`. Short version: edit `~/.config` and `~/.local`. Never edit `/usr/share/omarchy`. Hyprland user config is `~/.config/hypr`, and it reloads on save. Validate with `hyprctl reload` and `hyprctl configerrors` if you touch it. Do not touch Hyprland for this project unless the user asks for a fullscreen rule.

## Leave alone

- `~/.local/bin/launch-wow`, `~/.local/bin/launch-battlenet`, `~/.local/bin/battlenet-nvidia.sh`. WoW classic beta is Proton (GE-Proton), D3D12, prefix `~/Games/battlenet`. Do not set `__GLX_VENDOR_LIBRARY_NAME=nvidia`. Packaged `nvidia.lua` sets that into the user environment at login. The WoW launcher unsets it because Wine then fails `X_GLXCreateContext` and no window appears.
- Hybrid GPU: Intel Arc `8086:7d51` drives the internal panel (`renderD129`). RTX 5070 Max-Q `10de:2d18` is render-only (`renderD128`). GeForce NOW already picks the NVIDIA GPU through the flatpak. Do not invent offload vars for it.
- The plain GeForce NOW library launcher.
- Root needs a password. A reboot was not authorized.
- Do not kill WoW or a live GeForce NOW stream as part of development.

## Source session

Grok session `01a0f5ae-b1c8-74d0-a1ab-8da063a12d35`, title "GeForce NOW direct game launcher entries". The raw transcript is tool-heavy and includes logs that must not be copied into this repo. This file is the package. A shorter copy of the plan also lives in Grok workspace memory at `topics/gfn-omarchy-plugin.md` under `/home/mdance/.grok/memory-v2/workspaces/work-e3188367/`.
