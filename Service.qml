import QtQuick
import Quickshell
import Quickshell.Io
import "GfnModel.js" as GfnModel

// Headless singleton: owns catalog search / add-to-Apps / launch so the
// overlay can stay UI-focused. Mounted at enable time (manifest keepLoaded).
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // Absolute path to this plugin once installed under ~/.config/omarchy/plugins/
  readonly property string pluginDir: {
    var home = Quickshell.env("HOME") || ""
    var id = (root.manifest && root.manifest.id) ? root.manifest.id : "matt-dance.gfn"
    return home + "/.config/omarchy/plugins/" + id
  }

  readonly property string writerScript: root.pluginDir + "/scripts/write-desktop-entry.sh"
  readonly property string searchScript: root.pluginDir + "/scripts/gfn-catalog-search.py"
  readonly property string playScript: root.pluginDir + "/scripts/gfn-play.sh"

  property string lastAction: ""
  property string lastError: ""
  property var lastResults: []
  property string lastSearchQuery: ""
  property string lastAddLabel: ""
  property int searchGeneration: 0
  property int searchLimit: 40
  // cmsId → true for game+store variants already in ~/.local/share/matt-dance.gfn/games.json
  // Search MUST keep showing these rows (mark, do not hide/filter).
  property var addedCmsIds: ({})

  readonly property string catalogFile: {
    var home = Quickshell.env("HOME") || ""
    var xdg = Quickshell.env("XDG_DATA_HOME") || ""
    var base = xdg.length ? xdg : (home + "/.local/share")
    return base + "/matt-dance.gfn/games.json"
  }

  function notifySend(summary, body, urgency) {
    if (notifyProcess.running)
      notifyProcess.running = false
    notifyProcess.command = [
      "notify-send",
      "-a", "GeForce NOW Menu",
      "-u", String(urgency || "normal"),
      String(summary || "GeForce NOW Menu"),
      String(body || "")
    ]
    notifyProcess.running = true
  }

  function notifyFailure(summary, body) {
    root.notifySend(summary || "Could not add game", body || "", "normal")
  }

  function refreshCatalog() {
    if (catalogProcess.running)
      catalogProcess.running = false
    catalogProcess.command = GfnModel.catalogReadCommand(root.catalogFile)
    catalogProcess.running = true
  }

  function search(query) {
    // Async: scripts/gfn-catalog-search.py (GraphQL cache + local title filter).
    // Overlay watches lastAction / lastResults. Diablo IV fallback on failure.
    // Refresh catalog so "Already added" marks stay accurate after remove.
    root.refreshCatalog()
    root.lastAction = "search:pending"
    root.lastError = ""
    root.lastSearchQuery = String(query || "")
    root.searchGeneration += 1
    var gen = root.searchGeneration

    if (searchProcess.running)
      searchProcess.running = false

    searchProcess.generation = gen
    searchProcess.command = GfnModel.searchCommand(
      root.searchScript,
      root.lastSearchQuery,
      root.searchLimit
    )
    searchProcess.running = true
    return root.lastResults
  }

  function addToApps(game) {
    // Writes a .desktop entry via the companion script (Flatpak --url-route Exec).
    // Success notify-send lives in write-desktop-entry.sh; failures notify here.
    // Already-added variants: refuse re-add (no duplicate desktop/catalog/menu).
    root.lastAction = "addToApps"
    root.lastError = ""
    var g = game || {}
    root.lastAddLabel = GfnModel.addLabel(g)
    if (!g.cmsId || !(g.id || g.parentGameId)) {
      root.lastError = "missing cmsId or parentGameId — resolve from GraphQL catalog"
      root.lastAction = "addToApps:failed"
      root.notifyFailure("Could not add game", root.lastError)
      return false
    }
    if (GfnModel.isAlreadyAdded(g.cmsId, root.addedCmsIds) || g.alreadyAdded) {
      root.lastError = "game already added"
      root.lastAction = "addToApps:already"
      root.notifySend(
        "Already added",
        root.lastAddLabel + " is already in GeForce NOW Menu",
        "low"
      )
      return false
    }
    if (writerProcess.running) {
      root.lastError = "writer already running"
      root.lastAction = "addToApps:failed"
      root.notifyFailure("Could not add game", root.lastError)
      return false
    }
    writerProcess.command = GfnModel.writeDesktopEntryCommand(root.writerScript, g)
    writerProcess.running = true
    return true
  }

  Component.onCompleted: root.refreshCatalog()

  function launch(game) {
    // Proven CEF Flatpak launch (HANDOFF / gfn-play-diablo-iv).
    root.lastAction = "launch"
    root.lastError = ""
    var g = game || {}
    if (!g.cmsId || !(g.id || g.parentGameId)) {
      root.lastError = "missing cmsId or parentGameId — resolve from GraphQL catalog"
      return false
    }
    if (launchProcess.running) {
      root.lastError = "launch already running"
      return false
    }
    launchProcess.command = GfnModel.launchCommand(root.playScript, g)
    launchProcess.running = true
    return true
  }

  Process {
    id: catalogProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.addedCmsIds = GfnModel.parseCatalogCmsIds(text)
        // Re-mark visible results when catalog changes (add/remove) without hiding.
        if (root.lastResults && root.lastResults.length)
          root.lastResults = GfnModel.markAlreadyAdded(root.lastResults, root.addedCmsIds)
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      // Missing catalog file → empty map (nothing added yet).
      if (exitCode !== 0)
        root.addedCmsIds = root.addedCmsIds || ({})
    }
  }

  Process {
    id: searchProcess
    property int generation: 0

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (searchProcess.generation !== root.searchGeneration)
          return
        var rows = GfnModel.parseSearchOutput(text, root.lastSearchQuery)
        // Mark already-added variants; never filter them out of the list.
        root.lastResults = GfnModel.markAlreadyAdded(rows, root.addedCmsIds)
        root.lastAction = "search:done"
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (searchProcess.generation !== root.searchGeneration)
          return
        // Helper prints source=… diagnostics on stderr; keep as soft status, not hard error.
        var msg = String(text || "").trim()
        if (msg.length && (msg.indexOf("fallback") !== -1 || msg.indexOf("failed") !== -1
                           || msg.indexOf("No such file") !== -1 || msg.indexOf("not found") !== -1))
          root.lastError = msg
      }
    }

    onRunningChanged: {
      if (running)
        return
      if (searchProcess.generation !== root.searchGeneration)
        return
      // If the helper never produced stdout (missing python, bad path), fall back.
      Qt.callLater(function() {
        if (searchProcess.generation !== root.searchGeneration)
          return
        if (root.lastAction !== "search:pending")
          return
        root.lastResults = GfnModel.markAlreadyAdded(
          GfnModel.filterFallback(root.lastSearchQuery),
          root.addedCmsIds
        )
        if (!root.lastError || !String(root.lastError).length) {
          var script = String(root.searchScript || "")
          root.lastError = "catalog search helper failed to run (" + script + ") — Diablo IV fallback"
        }
        root.lastAction = "search:done"
      })
    }
  }

  Process {
    id: writerProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Script prints the written path on success (notify-send is in the script).
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && String(text).trim().length)
          root.lastError = String(text).trim()
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.lastError = ""
        root.lastAction = "addToApps:done"
        root.refreshCatalog()
        return
      }
      if (!root.lastError || !String(root.lastError).length)
        root.lastError = "Failed to write desktop entry (exit " + exitCode + ")"
      root.lastAction = "addToApps:failed"
      root.notifyFailure("Could not add game", root.lastError)
    }
  }

  Process {
    id: notifyProcess
  }

  Process {
    id: launchProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && String(text).trim().length)
          root.lastError = String(text).trim()
      }
    }
  }
}
