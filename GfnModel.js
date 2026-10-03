.pragma library

// Shared helpers for GeForce NOW search / add / launch.
// Launch uses Flatpak --url-route (see project docs/gfn-linux-launch.md).
// Do NOT invent authenticated GFN session APIs.

/**
 * Offline Diablo IV row (live catalog 2026-10-01). Used when the catalog
 * helper cannot reach network or cache. Re-verify ids before shipping.
 *
 * Each row: { id, cmsId, shortName, title, subtitle }
 *   id        — catalog UUID → parentGameId
 *   cmsId     — numeric CMS id (required for --url-route)
 *   shortName — variant slug; empty → game_gfn_pc at write/launch time
 */
function diabloFallback() {
  return [
    {
      id: "d32c9410-62cb-45cf-9c53-740bb92d4a2d",
      cmsId: "101069911",
      shortName: "",
      title: "Diablo IV",
      subtitle: "Offline fallback — cmsId 101069911"
    }
  ]
}

function enrichRow(row) {
  var r = row || {}
  var id = String(r.id || r.parentGameId || "")
  var cmsId = String(r.cmsId || "")
  var shortName = String(r.shortName || "")
  var title = String(r.title || "")
  var subtitle = String(r.subtitle || "")
  if (!subtitle.length) {
    var sn = shortName.length ? shortName : "game_gfn_pc (default)"
    subtitle = cmsId.length
      ? ("cmsId " + cmsId + " · shortName " + sn)
      : "Missing cmsId"
  }
  return {
    id: id,
    cmsId: cmsId,
    shortName: shortName,
    title: title,
    subtitle: subtitle
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
  var argv = ["python3", String(scriptPath)]
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
 * Effective shortName for --url-route (Klay default when catalog shortName is empty).
 */
function effectiveShortName(shortName) {
  var s = String(shortName || "").trim()
  return s.length ? s : "game_gfn_pc"
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
    "--title", String(g.title || "GeForce NOW Game")
  ]
  var sn = String(g.shortName || "").trim()
  if (sn.length)
    argv.push("--short-name", sn)
  return argv
}

/**
 * Flatpak --url-route launch for a catalog title.
 * Requires cmsId + id (parentGameId). shortName defaults to game_gfn_pc.
 */
function launchCommand(game) {
  var g = game || {}
  var cmsId = String(g.cmsId || "")
  var parentGameId = String(g.id || g.parentGameId || "")
  var shortName = effectiveShortName(g.shortName)
  var route = "#?cmsId=" + cmsId +
    "&launchSource=External&shortName=" + shortName +
    "&parentGameId=" + parentGameId
  return [
    "flatpak",
    "run",
    "--command=/app/cef/GeForceNOW",
    "com.nvidia.geforcenow",
    "--url-route=" + route
  ]
}
