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
      title: "Diablo IV",
      subtitle: "Steam · cmsId 102670811 · shortName (empty)"
    }
  ]
}

function enrichRow(row) {
  var r = row || {}
  var id = String(r.id || r.parentGameId || "")
  var cmsId = String(r.cmsId || "")
  var shortName = String(r.shortName || "")
  var appStore = String(r.appStore || "")
  var title = String(r.title || "")
  var subtitle = String(r.subtitle || "")
  if (!subtitle.length) {
    var sn = shortName.length ? shortName : "(empty)"
    var store = appStore.length ? (appStore + " · ") : ""
    subtitle = cmsId.length
      ? (store + "cmsId " + cmsId + " · shortName " + sn)
      : "Missing cmsId"
  }
  return {
    id: id,
    cmsId: cmsId,
    shortName: shortName,
    appStore: appStore,
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
  return argv
}

/**
 * Proven CEF Flatpak launch (same shape as gfn-play-diablo-iv).
 * Resolves NV_* driver envs at runtime via bash.
 * Requires cmsId + id (parentGameId). shortName may be empty.
 */
function launchCommand(game) {
  var g = game || {}
  var cmsId = String(g.cmsId || "")
  var parentGameId = String(g.id || g.parentGameId || "")
  var shortName = effectiveShortName(g.shortName)
  var route = "#?cmsId=" + cmsId +
    "&launchSource=External&shortName=" + shortName +
    "&parentGameId=" + parentGameId
  // Quote for bash single-quoted string: only ' needs escaping as '\'' 
  var routeQuoted = String(route).replace(/'/g, "'\\''")
  var script =
    'nv_host="$(flatpak --gl-drivers 2>/dev/null | grep -Eo \'^nvidia-[0-9-]+\' | head -n 1)"; ' +
    'exec flatpak run --user ' +
    '--command=/app/cef/GeForceNOW --cwd=/app/cef ' +
    '${nv_host:+--env=NV_HOST_DRIVER_VERSION="$nv_host"} ' +
    '${nv_host:+--env=NV_FLATPAK_DRIVER_VERSION="$nv_host"} ' +
    'com.nvidia.geforcenow ' +
    '--url-route=\'' + routeQuoted + '\''
  return ["bash", "-c", script]
}
