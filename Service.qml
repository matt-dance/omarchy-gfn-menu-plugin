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

  property string lastAction: ""
  property string lastError: ""
  property var lastResults: []
  property string lastSearchQuery: ""
  property int searchGeneration: 0
  property int searchLimit: 40

  function search(query) {
    // Async: scripts/gfn-catalog-search.py (GraphQL cache + local title filter).
    // Overlay watches lastAction / lastResults. Diablo IV fallback on failure.
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
    root.lastAction = "addToApps"
    root.lastError = ""
    var g = game || {}
    if (!g.cmsId || !(g.id || g.parentGameId)) {
      root.lastError = "missing cmsId or parentGameId — resolve from GraphQL catalog"
      return false
    }
    if (writerProcess.running) {
      root.lastError = "writer already running"
      return false
    }
    writerProcess.command = GfnModel.writeDesktopEntryCommand(root.writerScript, g)
    writerProcess.running = true
    return true
  }

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
    launchProcess.command = GfnModel.launchCommand(g)
    launchProcess.running = true
    return true
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
        root.lastResults = rows
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
        root.lastResults = GfnModel.filterFallback(root.lastSearchQuery)
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
        // Script prints the written path on success.
        root.lastAction = "addToApps:done"
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && String(text).trim().length)
          root.lastError = String(text).trim()
      }
    }
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
