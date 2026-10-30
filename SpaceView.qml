import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Space — "where did it go".
//
// The cleaner answers "what can I delete"; this answers the question that
// comes first. Two roots are worth looking at on a normal machine: $HOME,
// where everything the user does piles up, and /, which holds the system.
// `du -x` keeps each walk on one filesystem, so descending from $HOME never
// wanders into a mounted backup drive and never takes ten minutes to answer.
//
// Reading the sizes is still a full walk of the tree, so the first look at a
// folder is measured and shown as such. It is not cached: the numbers are the
// whole point, and a stale one is a lie.
Item {
  id: view

  // -------------------------------------------------------------- injected
  property string pluginDir: ""
  property color fg: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  property color dim: Util.alpha(Commons.Color.popups.text, 0.62)
  property color faint: Util.alpha(Commons.Color.popups.text, 0.38)
  property color success: "#3ecf72"
  property color warning: "#f0a83c"
  property color danger: "#ef5f5f"
  property string fontFamily: Style.font.family
  property real maxHeight: Style.space(420)
  property Item keyTarget: null

  // ----------------------------------------------------------------- state
  // home | root — which tree the walk starts from. `home` is sent with no
  // path so the backend resolves $HOME itself; that keeps the shell's idea of
  // home and the panel's idea of home from ever disagreeing.
  property string rootKind: "home"
  property string path: ""
  property var items: []
  property real total: 0
  property int cursor: 0
  property bool loading: false
  property bool measured: false
  property string error: ""
  property string notice: ""
  property var trail: []

  // Paths the cleaner has been told to leave alone, so the view can say so.
  property var ignored: []

  readonly property string stateScript: view.pluginDir + "/scripts/tidy-state"
  readonly property string python: "/usr/bin/python3"

  readonly property real rowHeight: Style.space(26)
  readonly property var current: view.items.length === 0
    ? null
    : view.items[Math.max(0, Math.min(view.cursor, view.items.length - 1))]

  function homeLabel() {
    return view.rootKind === "home" ? "Home" : "/"
  }

  // The last two segments, so a deep path stays readable in one line.
  function shortPath(value) {
    if (value === "") return "…"
    var parts = value.split("/").filter(function(part) { return part !== "" })
    if (parts.length <= 3) return value
    return "…/" + parts.slice(parts.length - 3).join("/")
  }

  function isIgnored(target) {
    if (!target) return false
    for (var i = 0; i < view.ignored.length; i++) {
      var entry = view.ignored[i]
      if (entry === target) return true
      if (entry !== "/" && target.indexOf(entry + "/") === 0) return true
    }
    return false
  }

  // ------------------------------------------------------------ lifecycle
  function start() {
    if (view.loading) return
    if (!view.measured) view.reload()
    if (!ignoreProc.running) ignoreProc.running = true
  }

  function reload() {
    if (spaceProc.running) return
    view.loading = true
    view.error = ""
    view.notice = ""
    view.cursor = 0
    if (view.rootKind === "root" && view.path === "") {
      // "/" and $HOME are the two entry points; everything else is a child.
      spaceProc.command = [view.python, view.stateScript, "space", "/", "1"]
    } else if (view.path === "") {
      spaceProc.command = [view.python, view.stateScript, "space"]
    } else {
      spaceProc.command = [view.python, view.stateScript, "space", view.path, "1"]
    }
    spaceProc.running = true
  }

  function switchRoot(kind) {
    if (view.rootKind === kind && view.trail.length === 0) return
    view.rootKind = kind
    view.path = ""
    view.trail = []
    view.items = []
    view.total = 0
    view.measured = false
    view.reload()
  }

  function open(target) {
    if (!target || target === view.path) return
    view.trail = view.trail.concat([view.path])
    view.path = target
    view.reload()
  }

  function up() {
    if (view.trail.length === 0) return false
    var next = view.trail.slice(0, view.trail.length - 1)
    var target = view.trail[view.trail.length - 1]
    view.trail = next
    view.path = target
    view.reload()
    return true
  }

  function drill(index) {
    var item = view.items[index]
    if (!item) return
    view.open(item.path)
  }

  function moveCursor(delta) {
    if (view.items.length === 0) return
    view.cursor = Math.max(0, Math.min(view.items.length - 1, view.cursor + delta))
    listFlick.ensureVisible(view.cursor)
  }

  function ignoreCurrent() {
    var item = view.current
    if (!item) return
    ignoreAdd.command = [view.python, view.stateScript, "ignore-add", item.path]
    ignoreAdd.running = true
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      // Walking back up outranks closing the panel; the panel closes only at
      // the top, where there is nowhere left to go.
      if (view.up()) event.accepted = true
      return
    }
    if (event.key === Qt.Key_Down || event.text === "j") {
      view.moveCursor(1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Up || event.text === "k") {
      view.moveCursor(-1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_PageDown) {
      view.moveCursor(8)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_PageUp) {
      view.moveCursor(-8)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Right || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      view.drill(view.cursor)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Backspace || event.text === "h") {
      view.up()
      event.accepted = true
      return
    }
    if (event.text === "i" || event.text === "I") {
      view.ignoreCurrent()
      event.accepted = true
      return
    }
    if (event.text === "r" || event.text === "R") {
      view.reload()
      event.accepted = true
      return
    }
    if (event.text === "~" || event.text === "g" || event.text === "G") {
      view.switchRoot("home")
      event.accepted = true
      return
    }
    if (event.text === "/") {
      view.switchRoot("root")
      event.accepted = true
    }
  }

  // -------------------------------------------------------------- processes
  Process {
    id: spaceProc
    stdout: StdioCollector {
      id: spaceOut
      waitForEnd: true
    }
    onExited: function(code) {
      view.loading = false
      var text = String(spaceOut.text || "").replace(/^\s+|\s+$/g, "")
      var data = null
      try {
        data = JSON.parse(text)
      } catch (error) {
        data = null
      }
      if (!data || !data.ok) {
        view.error = data && data.error ? data.error : "Could not measure " + view.shortPath(view.path)
        return
      }
      view.path = data.path || ""
      view.total = Number(data.total) || 0
      view.items = data.items || []
      view.cursor = 0
      view.measured = true
      view.error = ""
      listFlick.contentY = 0
    }
  }

  Process {
    id: ignoreProc
    command: [view.python, view.stateScript, "ignore-list"]
    stdout: StdioCollector {
      id: ignoreOut
      waitForEnd: true
    }
    onExited: {
      var text = String(ignoreOut.text || "").replace(/^\s+|\s+$/g, "")
      if (text.length === 0) return
      var data = null
      try {
        data = JSON.parse(text)
      } catch (error) {
        return
      }
      if (data && data.ok && data.paths) view.ignored = data.paths
    }
  }

  Process {
    id: ignoreAdd
    stdout: StdioCollector {
      id: ignoreAddOut
      waitForEnd: true
    }
    onExited: {
      var text = String(ignoreAddOut.text || "").replace(/^\s+|\s+$/g, "")
      var data = null
      try {
        data = JSON.parse(text)
      } catch (error) {
        data = null
      }
      if (data && data.ok) {
        view.notice = "Tidy will never touch " + view.shortPath(view.current ? view.current.path : "")
        if (!ignoreProc.running) ignoreProc.running = true
      } else {
        view.notice = data && data.error ? data.error : "Could not ignore that folder"
      }
    }
  }

  // A small pill for the two roots. Declared at file scope because that is
  // the only scope an inline component is reachable from.
  component RootTab: Rectangle {
    id: tab
    property string label: ""
    property string value: "home"
    readonly property bool active: view.rootKind === tab.value
    implicitWidth: tabLabel.implicitWidth + Style.space(16)
    implicitHeight: Style.space(22)
    radius: Style.cornerRadius
    color: tab.active ? view.accent : Util.alpha(view.fg, 0.05)
    border.width: Math.max(1, Style.space(1))
    border.color: tab.active ? "transparent" : Util.alpha(view.fg, 0.10)

    Behavior on color { ColorAnimation { duration: 110 } }

    Text {
      id: tabLabel
      anchors.centerIn: parent
      text: tab.label
      color: tab.active ? view.readableOn(view.accent) : view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: tab.active
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: view.switchRoot(tab.value)
    }
  }

  implicitHeight: layout.height
  height: layout.height

  readonly property real chromeHeight: headRow.height + barRow.height
    + hintRow.height + layout.spacing * 3
  readonly property real listHeight: Math.max(Style.space(96), view.maxHeight - view.chromeHeight)

  // ------------------------------------------------------------------ view
  Column {
    id: layout
    width: parent.width
    spacing: Style.space(10)

    // ------------------------------------------------------------- header
    Item {
      id: headRow
      width: parent.width
      height: Math.max(rootChip.implicitHeight, pathLabel.implicitHeight, totalLabel.implicitHeight)
        + Style.space(2)

      Row {
        id: rootChip
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        RootTab { label: "Home"; value: "home" }
        RootTab { label: "/"; value: "root" }
      }

      Text {
        id: pathLabel
        anchors.left: rootChip.right
        anchors.leftMargin: Style.space(10)
        anchors.right: totalLabel.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: view.loading && !view.measured
          ? "Measuring " + view.shortPath(view.path || view.homeLabel()) + "…"
          : view.shortPath(view.path) + (view.trail.length > 0 ? "   ← backspace" : "")
        color: view.loading && !view.measured ? view.dim : view.fg
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideMiddle
      }

      Text {
        id: totalLabel
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: view.measured ? Model.formatBytes(view.total) : ""
        color: view.accent
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    // ---------------------------------------------------------------- bar
    // One bar for the folder as a whole, split by its children, so the shape
    // of the disk is legible before any row is read.
    Item {
      id: barRow
      width: parent.width
      height: Style.space(6)

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
        color: Util.alpha(view.fg, 0.09)
      }

      Repeater {
        model: view.items.slice(0, 8)

        delegate: Rectangle {
          required property var modelData
          required property int index
          readonly property real share: view.total > 0 ? modelData.bytes / view.total : 0
          readonly property real gap: Style.space(2)
          readonly property real usable: barRow.width - gap * Math.max(0, Math.min(8, view.items.length) - 1)
          x: {
            var offset = 0
            var n = Math.min(8, view.items.length)
            for (var i = 0; i < index && i < n; i++)
              offset += (view.items[i].bytes / view.total)
            return Math.round(offset * usable + index * gap)
          }
          width: Math.max(2, Math.round(share * usable))
          height: barRow.height
          radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
          color: Util.alpha(view.accent, 1.0 - Math.min(0.6, index * 0.12))
        }
      }
    }

    // --------------------------------------------------------------- list
    Flickable {
      id: listFlick
      width: parent.width
      height: view.listHeight
      contentWidth: width
      contentHeight: listCol.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      function ensureVisible(index) {
        var y = index * view.rowHeight
        if (y < contentY) contentY = y
        else if (y + view.rowHeight > contentY + height)
          contentY = Math.min(y + view.rowHeight - height,
            Math.max(0, contentHeight - height))
      }

      Column {
        id: listCol
        width: listFlick.width

        Repeater {
          model: view.items

          delegate: Item {
            id: row
            required property var modelData
            required property int index

            readonly property bool hasCursor: view.cursor === index
            readonly property bool hot: rowArea.containsMouse
            readonly property real share: view.total > 0 ? modelData.bytes / view.total : 0
            readonly property bool gone: view.isIgnored(modelData.path)

            width: listCol.width
            height: view.rowHeight

            // The proportional fill sits behind the label: a row's size is
            // easier to feel than to read.
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.rightMargin: Style.space(2)
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height - Style.space(4)
              radius: Style.cornerRadius
              color: row.hasCursor ? Util.alpha(view.accent, 0.20)
                : row.hot ? Util.alpha(view.fg, 0.06)
                : "transparent"

              Behavior on color { ColorAnimation { duration: 110 } }
            }

            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(2, Math.round(row.share * (row.width - Style.space(4))))
              height: parent.height - Style.space(10)
              radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
              color: Util.alpha(view.accent, row.hasCursor ? 0.34 : 0.16)
              opacity: row.gone ? 0.4 : 1.0
            }

            Text {
              id: rowName
              anchors.left: parent.left
              anchors.leftMargin: Style.space(9)
              anchors.right: rowSize.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: row.modelData.name
              color: row.gone ? view.faint : view.fg
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              id: rowIgnored
              anchors.right: rowSize.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              visible: row.gone
              text: "ignored"
              color: view.success
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              id: rowSize
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.formatBytes(row.modelData.bytes)
              color: row.hasCursor ? view.fg : view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                view.cursor = row.index
                view.drill(row.index)
              }
            }
          }
        }
      }

      ScrollKnob { flick: listFlick }
    }

    // --------------------------------------------------------------- hint
    Item {
      id: hintRow
      width: parent.width
      height: Math.max(hintText.implicitHeight, ignoreButton.implicitHeight)

      Text {
        id: hintText
        anchors.left: parent.left
        anchors.right: ignoreButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: view.error !== "" ? view.error
          : view.notice !== "" ? view.notice
          : view.loading ? "Measuring… this walks the folder, so give it a moment."
          : view.items.length === 0 ? "Nothing of any size in here."
          : "Enter opens · Backspace up · i ignore · r remeasure"
        color: view.error !== "" ? view.danger : view.notice !== "" ? view.success : view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Button {
        id: ignoreButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Ignore this folder"
        iconText: "\uf05e"
        tooltipText: "Tell the cleaner to leave this folder alone, now and in every future clean."
        foreground: view.fg
        accent: view.accent
        fontFamily: view.fontFamily
        fontSize: Style.font.bodySmall
        bordered: true
        visible: view.current !== null
        focusable: false
        onClicked: view.ignoreCurrent()
      }
    }
  }

  // The panel's own readability helper, duplicated rather than reached for
  // through a parent that may not be in scope.
  function readableOn(color) {
    var r = color.r
    var g = color.g
    var b = color.b
    var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return lum > 0.62 ? "#101315" : "#ffffff"
  }

  // Panel.qml declares this inline, and an inline component is not visible from
  // another file, so the view carries its own copy. Same shape as the rest of
  // the plugin: a thin bar that only appears when there is somewhere to scroll.
  component ScrollKnob: Rectangle {
    id: knob
    required property Flickable flick

    readonly property real span: Math.max(1, knob.flick.contentHeight - knob.flick.height)
    readonly property bool scrollable: knob.flick.contentHeight > knob.flick.height + 1

    visible: knob.scrollable
    width: Style.space(3)
    height: Math.max(Style.space(22), knob.flick.height * knob.flick.height
      / Math.max(1, knob.flick.contentHeight))
    radius: width / 2
    color: Util.alpha(view.fg, 0.20)
    x: knob.flick.width - knob.width - Style.space(1)
    y: knob.flick.contentY + (knob.flick.height - knob.height)
      * (knob.flick.contentY / knob.span)
  }
}
