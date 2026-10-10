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

  function notifyFailure(summary, body) {
    if (notifyProcess.running)
      notifyProcess.running = false
    notifyProcess.command = [
      "notify-send",
      "-a", "GeForce NOW Menu",
      "-u", "normal",
      String(summary || "Could not add game"),
      String(body || "")
    ]
    notifyProcess.running = true
  }

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
    // Success notify-send lives in write-desktop-entry.sh; failures notify here.
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
