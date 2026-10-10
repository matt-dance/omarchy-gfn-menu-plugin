.pragma library

// Shared helpers for GeForce NOW search / add / launch.
// Launch matches proven CEF path (HANDOFF / gfn-play-diablo-iv).
// Do NOT invent authenticated GFN session APIs.

/**
 * Offline Diablo IV row (proven Steam variant). Used when the catalog
 * helper cannot reach network or cache.
 *
 * Each row: { id, cmsId, shortName, title, subtitle, appStore }
 *   id        — catalog UUID → parentGameId
 *   cmsId     — *variant* CMS id (Steam preferred; not top-level GFNDB id)
 *   shortName — variant slug; empty is valid for --url-route
 *   appStore  — STEAM / BATTLENET / …
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
      subtitle: "Steam · GFN · cmsId 102670811 · shortName (empty)"
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
 * Label used in overlay status + notify: "Steam · Diablo IV".
 */
function addLabel(game) {
  var g = game || {}
  var title = String(g.title || "game").trim() || "game"
  var store = humanizeStore(g.appStore)
  return store.length ? (store + " · " + title) : title
}

function enrichRow(row) {
  var r = row || {}
  var id = String(r.id || r.parentGameId || "")
  var cmsId = String(r.cmsId || "")
  var shortName = String(r.shortName || "")
  var appStore = String(r.appStore || "")
  var boxArt = String(r.boxArt || "")
  var title = String(r.title || "")
  var subtitle = String(r.subtitle || "")
  var alreadyAdded = !!r.alreadyAdded
  if (!subtitle.length) {
    var sn = shortName.length ? shortName : "(empty)"
    var storePretty = humanizeStore(appStore)
    // Store first — overlay ElideRight was clipping store off long titles.
    var store = storePretty.length ? (storePretty + " · ") : ""
    subtitle = cmsId.length
      ? (store + "GFN · cmsId " + cmsId + " · shortName " + sn)
      : "Missing cmsId"
  }
  return {
    id: id,
    cmsId: cmsId,
    shortName: shortName,
    appStore: appStore,
    boxArt: boxArt,
    title: title,
    subtitle: subtitle,
    alreadyAdded: alreadyAdded
  }
}

/**
 * Read argv for games.json (added cmsIds). catalogFile is absolute.
 */
function catalogReadCommand(catalogFile) {
  return ["cat", String(catalogFile || "")]
}

/**
 * Parse games.json into { cmsId: true, ... }. Never throws.
 */
function parseCatalogCmsIds(text) {
  var out = {}
  var raw = String(text || "").trim()
  if (!raw.length)
    return out
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed.length !== "number")
      return out
    for (var i = 0; i < parsed.length; i++) {
      var cms = String((parsed[i] && parsed[i].cmsId) || "").trim()
      if (cms.length)
        out[cms] = true
    }
  } catch (e) {}
  return out
}

/**
 * Mark search rows that are already in the local catalog.
 * IMPORTANT: do NOT filter/hide them — show with "Already added" subtitle.
 * Safe to call repeatedly (strips a previous mark before re-applying).
 */
function markAlreadyAdded(rows, addedCmsIds) {
  var map = addedCmsIds || {}
  var list = rows || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var src = list[i] || {}
    // Drop stale mark so remove → re-search clears the status.
    var clean = {}
    for (var k in src)
      clean[k] = src[k]
    clean.alreadyAdded = false
    var sub0 = String(clean.subtitle || "")
    if (sub0.indexOf("Already added · ") === 0)
      clean.subtitle = sub0.slice("Already added · ".length)
    else if (sub0 === "Already added" || sub0 === "game already added")
      clean.subtitle = ""
    var row = enrichRow(clean)
    var cms = String(row.cmsId || "")
    var added = !!(cms.length && map[cms])
    row.alreadyAdded = added
    if (added) {
      // Keep store/cms details; lead with clear status for the overlay.
      var base = String(row.subtitle || "")
      row.subtitle = base.length ? ("Already added · " + base) : "Already added"
    }
    out.push(row)
  }
  return out
}

function isAlreadyAdded(cmsId, addedCmsIds) {
  var cms = String(cmsId || "").trim()
  if (!cms.length)
    return false
  var map = addedCmsIds || {}
  return !!map[cms]
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
  return String(shortName || "").trim()
}

/**
 * Build argv for the companion desktop-entry writer script.
 * scriptPath should be an absolute path under the installed plugin dir.
 */
function writeDesktopEntryCommand(scriptPath, game) {
  var g = game || {}
  var argv = [
    "bash",
    String(scriptPath),
    "--cms-id", String(g.cmsId || ""),
    "--parent-game-id", String(g.id || g.parentGameId || ""),
    "--title", String(g.title || "GeForce NOW Game"),
    "--force"
  ]
  // Always pass --short-name so an empty catalog value stays empty
  // (writer must not invent game_gfn_pc).
  argv.push("--short-name", effectiveShortName(g.shortName))
  // Always pass store + box art when present so overlay adds keep icons/labels.
  argv.push("--app-store", String(g.appStore || ""))
  var box = String(g.boxArt || "")
  if (box.length)
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
    "--title", String(g.title || "GeForce NOW game")
  ]
  return argv
}
