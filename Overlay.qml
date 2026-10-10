import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "GfnModel.js" as GfnModel

// Fullscreen search overlay for GeForce NOW titles.
// Summon: omarchy-shell shell summon matt-dance.gfn '{}'
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var results: []
  property string statusText: "GFN catalog search — type a title, then Enter (cache TTL ~6h)"
  property var boundService: null

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.title + Style.spacing.md)

  function service() {
    if (!root.pluginRegistry || typeof root.pluginRegistry.getService !== "function")
      return null
    var id = (root.manifest && root.manifest.id) ? root.manifest.id : "matt-dance.gfn"
    return root.pluginRegistry.getService(id)
  }

  function bindService() {
    root.boundService = root.service()
  }

  function applyResults(rows, pending) {
    root.results = rows || []
    displayModel.clear()
    for (var i = 0; i < root.results.length; i++) {
      var row = root.results[i]
      displayModel.append({
        gameId: String(row.id || ""),
        cmsId: String(row.cmsId || ""),
        shortName: String(row.shortName || ""),
        appStore: String(row.appStore || ""),
        title: String(row.title || ""),
        subtitle: String(row.subtitle || "")
      })
    }

    if (displayModel.count === 0)
      selectedIndex = 0
    else if (selectedIndex >= displayModel.count)
      selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0)
      selectedIndex = 0

    cursorActive = displayModel.count > 0

    if (pending) {
      root.statusText = "Searching GFN catalog…"
      return
    }

    var svc = root.boundService
    var err = (svc && svc.lastError) ? String(svc.lastError) : ""
    var q = root.filterText ? String(root.filterText).trim() : ""
    if (!q.length && displayModel.count === 0) {
      root.statusText = "Type a title, then press Enter to search the GFN catalog (cached ~6h)"
      return
    }
    if (displayModel.count === 0) {
      root.statusText = err.length
        ? ("No matches — " + err)
        : "No matches — try another title"
    } else if (err.indexOf("fallback") !== -1) {
      root.statusText = displayModel.count + " result(s) — offline Diablo IV fallback"
    } else {
      root.statusText = displayModel.count + " result(s) — Enter writes Apps .desktop with --url-route"
    }
  }

  function open(payloadJson) {
    root.bindService()
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    root.results = []
    displayModel.clear()
    root.statusText = "Type a title, then press Enter to search the GFN catalog (cached ~6h)"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "matt-dance.gfn")
  }

  function toggle() {
    if (root.opened)
      root.dismiss()
    else
      root.open("{}")
  }

  function runSearch(query) {
    root.bindService()
    var svc = root.boundService
    if (svc && typeof svc.search === "function") {
      root.statusText = "Searching GFN catalog…"
      svc.search(query)
      // Keep current list until search:done; show pending status.
      return
    }

    // No service Process — sync Diablo IV fallback only.
    root.applyResults(GfnModel.search(query), false)
  }

  function setFilter(nextFilter) {
    // Typing only updates the query string. Enter (Keys Return/Enter) runs
    // the catalog search Process — see keyCatcher below.
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = false
    var q = nextFilter ? String(nextFilter).trim() : ""
    if (!q.length) {
      root.results = []
      displayModel.clear()
      root.statusText = "Type a title, then press Enter to search the GFN catalog (cached ~6h)"
    } else {
      root.statusText = "Press Enter to search GFN for “" + q + "”"
    }
  }

  function select(delta) {
    if (displayModel.count === 0)
      return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count)
      return
    var row = displayModel.get(index)
    var game = {
      id: row.gameId,
      cmsId: row.cmsId,
      shortName: row.shortName,
      appStore: row.appStore,
      title: row.title
    }
    var svc = root.service()
    if (!row.cmsId || !row.gameId) {
      root.statusText = "“" + row.title + "” has no cmsId yet — resolve from GraphQL catalog"
      return
    }
    if (svc && typeof svc.addToApps === "function") {
      if (svc.addToApps(game))
        root.statusText = "Writing Apps launcher for “" + row.title + "” (Flatpak --url-route)"
      else
        root.statusText = svc.lastError || "Could not write .desktop entry"
    } else {
      root.statusText = "Service unavailable — cannot write .desktop entry"
    }
  }

  Connections {
    target: root.boundService
    function onLastActionChanged() {
      var svc = root.boundService
      if (!svc)
        return
      if (svc.lastAction === "search:pending")
        root.statusText = "Searching GFN catalog…"
      else if (svc.lastAction === "search:done")
        root.applyResults(svc.lastResults || [], false)
    }
    function onLastResultsChanged() {
      var svc = root.boundService
      if (!svc || svc.lastAction !== "search:done")
        return
      root.applyResults(svc.lastResults || [], false)
    }
  }

  ListModel { id: displayModel }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "matt-dance-gfn"

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText)
              root.setFilter("")
            else
              root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            // Enter submits catalog search when there is a query and nothing
            // to activate yet. With results + cursor, Enter writes the Apps
            // .desktop (activateIndex). Previously cursorActive was forced
            // true while typing, so Enter always hit activateIndex(0) on an
            // empty model and silently returned — "Enter does nothing".
            var q = root.filterText ? String(root.filterText).trim() : ""
            if (displayModel.count > 0 && root.cursorActive) {
              root.activateIndex(root.selectedIndex)
            } else if (q.length) {
              root.runSearch(q)
            } else if (displayModel.count > 0) {
              root.cursorActive = true
            } else {
              root.statusText = "Type a title, then press Enter to search"
            }
            event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32
                     && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search GeForce NOW…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.statusText
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        ListView {
          id: resultList
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing * 2
                  - Style.font.caption * 2
          model: displayModel
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.space(2)

          delegate: Rectangle {
            required property int index
            required property string gameId
            required property string cmsId
            required property string shortName
            required property string appStore
            required property string title
            required property string subtitle

            readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

            width: resultList.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: hasCursor ? root.selectedBackground : "transparent"

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: title
                color: hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: subtitle
                color: hasCursor ? root.selectedText : root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) {
                root.cursorActive = true
                root.selectedIndex = index
              }
              onClicked: {
                root.cursorActive = true
                root.selectedIndex = index
                root.activateIndex(index)
              }
            }
          }
        }
      }
    }
  }
}
