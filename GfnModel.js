.pragma library

// Shared helpers for GeForce NOW search / add / launch.
// Launch matches proven CEF path (HANDOFF / gfn-play-diablo-iv).
// Do NOT invent authenticated GFN session APIs.

/**
 * Offline Diablo IV row (proven Steam variant). Used when the catalog
 * helper cannot reach network or cache.
 *
 * Each row: { id, cmsId, shortName, title, subtitle, appStore, alreadyAdded? }
 *   id        — catalog UUID → parentGameId
 *   cmsId     — *variant* CMS id (Steam preferred; not top-level GFNDB id)
 *   shortName — variant slug; empty is valid for --url-route
 *   appStore  — STEAM / BATTLENET / …
 *   alreadyAdded — true when game+store is already in games.json / desktops
 */
function diabloFallback() {
  return [
    {
      id: "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
      cmsId: "102670811",
      shortName: "",
      appStore: "STEAM",
      boxArt: "",
      title: "Diablo IV",
      subtitle: "Steam",
      alreadyAdded: false
    }
  ]
}

/**
 * Humanize catalog appStore codes for UI / notify-send (Steam not STEAM).
 */
function humanizeStore(appStore) {
  var su = String(appStore || "").trim().toUpperCase()
  if (su === "STEAM") return "Steam"
  if (su === "BATTLENET") return "Battle.net"
  if (su === "EPIC") return "Epic"
  if (su === "GOG") return "GOG"
  if (su === "UPLAY" || su === "UBISOFT") return "Ubisoft"
  if (su === "EA") return "EA"
  if (!su.length) return ""
  // Title-case unknown store tokens.
  return String(appStore || "").charAt(0).toUpperCase()
    + String(appStore || "").slice(1).toLowerCase()
}

/**
 * Bare game name with any leading "GFN - " prefixes removed.
 * Overlay enrichRow prefixes for display; writers must get the bare title.
 */
function bareTitle(title, fallback) {
  var t = String(title || "").trim()
  while (t.indexOf("GFN - ") === 0)
    t = t.slice(6).trim()
  return t || (fallback || "game")
}

/**
 * Primary list/menu label: "GFN - Diablo IV" (idempotent).
 */
function primaryLabel(game) {
  var g = game || {}
  return "GFN - " + bareTitle(g.title, "game")
}

/**
 * Label used in overlay status + notify: "GFN - Diablo IV".
 */
function addLabel(game) {
  return primaryLabel(game)
}

function isAlreadyAdded(row) {
  var r = row || {}
  if (r.alreadyAdded === true || r.alreadyAdded === 1 || r.alreadyAdded === "true")
    return true
  return false
}

/**
 * Catalog IDs that are safe to write into .desktop keys / --url-route.
 * Matches scripts/write-desktop-entry.sh and gfn-play.sh.
 */
function isSafeId(value) {
  return /^[A-Za-z0-9._-]{1,64}$/.test(String(value || ""))
}

function isSafeOptionalId(value) {
  var s = String(value || "")
  return s.length === 0 || isSafeId(s)
}

function stripControls(text) {
  return String(text || "").replace(/[\x00-\x1F\x7F]/g, "")
}

function isHttpsUrl(url) {
  var u = String(url || "")
  if (!u.length || /[\x00-\x1F\x7F]/.test(u))
    return false
  return /^https:\/\/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+$/.test(u)
}

function enrichRow(row) {
  var r = row || {}
  var id = stripControls(String(r.id || r.parentGameId || ""))
  var cmsId = stripControls(String(r.cmsId || ""))
  var shortName = stripControls(String(r.shortName || ""))
  var appStore = stripControls(String(r.appStore || ""))
  var boxArt = String(r.boxArt || "")
  if (!isHttpsUrl(boxArt))
    boxArt = ""
  var title = stripControls(String(r.title || ""))
  var alreadyAdded = isAlreadyAdded(r)
  var storePretty = humanizeStore(appStore)
  var displayTitle = primaryLabel({ title: title })
  var subtitle = stripControls(String(r.subtitle || ""))
  // Matt UX: already-added stays visible; otherwise store is the small print.
  if (alreadyAdded) {
    subtitle = "game already added"
  } else if (!subtitle.length) {
    subtitle = storePretty.length ? storePretty : (cmsId.length ? ("cmsId " + cmsId) : "GeForce NOW")
  }
  return {
    id: id,
    cmsId: cmsId,
    shortName: shortName,
    appStore: appStore,
    boxArt: boxArt,
    title: displayTitle,
    subtitle: subtitle,
    alreadyAdded: alreadyAdded
  }
}

/**
 * Local filter of the offline Diablo IV fallback (no network).
 */
function filterFallback(query) {
  var q = String(query || "").trim().toLowerCase()
  var catalog = diabloFallback()
  if (!q)
    return []
  var out = []
  for (var i = 0; i < catalog.length; i++) {
    var row = catalog[i]
    var title = String(row.title).toLowerCase()
    // Tolerate "diablo iv" vs trademark glyphs by simple token check.
    if (title.indexOf(q) !== -1 || (q.indexOf("diablo") !== -1 && q.indexOf("iv") !== -1))
      out.push(enrichRow(row))
  }
  return out
}

/**
 * Sync search used when the helper Process is unavailable.
 * Prefers Diablo IV offline fallback only — live catalog goes through
 * scripts/gfn-catalog-search.py (Service.search).
 */
function search(query) {
  return filterFallback(query)
}

/**
 * Build argv for scripts/gfn-catalog-search.py
 */
function searchCommand(scriptPath, query, limit) {
  // Absolute python3 so Quickshell Process does not depend on a thin PATH.
  var argv = ["/usr/bin/python3", String(scriptPath)]
  var q = String(query || "")
  if (q.length)
    argv.push(q)
  var lim = parseInt(limit, 10)
  if (!lim || lim < 1)
    lim = 40
  argv.push("--limit", String(lim))
  return argv
}

/**
 * Parse helper stdout (JSON array) into enriched rows.
 * On parse failure, returns Diablo IV fallback filtered by query.
 */
function parseSearchOutput(text, query) {
  var raw = String(text || "").trim()
  if (!raw.length)
    return filterFallback(query)
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed.length !== "number")
      return filterFallback(query)
    var out = []
    for (var i = 0; i < parsed.length; i++)
      out.push(enrichRow(parsed[i]))
    return out
  } catch (e) {
    return filterFallback(query)
  }
}

/**
 * shortName for --url-route. Empty string is valid (proven Diablo IV).
 */
function effectiveShortName(shortName) {
  return stripControls(String(shortName || "")).trim()
}

/**
 * Build argv for the companion desktop-entry writer script.
 * scriptPath should be an absolute path under the installed plugin dir.
 */
function writeDesktopEntryCommand(scriptPath, game) {
  var g = game || {}
  // Pass bare title: enrichRow may already set title to "GFN - <Game>".
  var argv = [
    "bash",
    String(scriptPath),
    "--cms-id", String(g.cmsId || ""),
    "--parent-game-id", String(g.id || g.parentGameId || ""),
    "--title", bareTitle(stripControls(String(g.title || "")), "GeForce NOW Game"),
    "--force"
  ]
  // Always pass --short-name so an empty catalog value stays empty
  // (writer must not invent game_gfn_pc).
  argv.push("--short-name", effectiveShortName(g.shortName))
  // Always pass store + box art when present so overlay adds keep icons/labels.
  argv.push("--app-store", String(g.appStore || ""))
  var box = String(g.boxArt || "")
  if (box.length && isHttpsUrl(box))
    argv.push("--box-art-url", box)
  return argv
}

/**
 * Launch via scripts/gfn-play.sh (busy-guard + proven CEF Flatpak path).
 * playScriptPath should be absolute under the installed plugin dir.
 * Requires cmsId + id (parentGameId). shortName may be empty.
 */
function launchCommand(playScriptPath, game) {
  var g = game || {}
  var argv = [
    "bash",
    String(playScriptPath),
    "--cms-id", String(g.cmsId || ""),
    "--parent-game-id", String(g.id || g.parentGameId || ""),
    "--short-name", effectiveShortName(g.shortName),
    "--title", bareTitle(stripControls(String(g.title || "")), "GeForce NOW game")
  ]
  return argv
}
