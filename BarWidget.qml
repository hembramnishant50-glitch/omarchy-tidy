import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Tidy's bar icon, and a small answer to the question the icon implies:
// how much room is left. A thin ring around the glyph fills with the used
// fraction of the root filesystem and turns amber once free space drops
// under 5 GiB — the point where a cleaner stops being housekeeping and
// starts being necessary. The percentage itself lives in the tooltip; at
// 27px there is no room for a legible number.
BarWidget {
  id: root
  moduleName: "nishant.tidy"
  implicitWidth: Style.bar.iconSlot
  implicitHeight: Style.bar.iconSlot

  // The panel resolves this the same way; keeping a second copy here costs a
  // property and saves the widget from depending on a lazily-built sibling.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.slice(7)
    url = decodeURIComponent(url)
    if (url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
    return url
  }
  readonly property string stateScript: root.pluginDir + "/scripts/tidy-state"

  readonly property color fg: root.bar ? root.bar.barForeground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color warning: "#f0a83c"

  // How much room is left, in bytes. -1 until the first read lands, so the
  // ring stays empty rather than claiming the disk is full.
  property real freeBytes: -1
  property real totalBytes: 0

  // Below this the ring goes amber. 5 GiB is roughly one desktop update plus
  // a browser cache — enough headroom that the warning arrives before the
  // machine does something dramatic about it.
  readonly property real warnFree: 5 * 1024 * 1024 * 1024

  readonly property bool known: root.freeBytes >= 0 && root.totalBytes > 0
  readonly property bool low: root.known && root.freeBytes < root.warnFree
  readonly property real usedFraction: root.known
    ? Math.max(0, Math.min(1, (root.totalBytes - root.freeBytes) / root.totalBytes))
    : 0

  function human(bytes) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var value = Number(bytes) || 0
    var i = 0
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024
      i++
    }
    return (value >= 100 || i === 0 ? Math.round(value)
      : value >= 10 ? value.toFixed(0) : value.toFixed(1)) + " " + units[i]
  }

  readonly property string tooltip: !root.known
    ? "Tidy — free up disk space"
    : root.low
      ? "Tidy — only " + root.human(root.freeBytes) + " left. Open to free space."
      : "Tidy — " + root.human(root.freeBytes) + " free of " + root.human(root.totalBytes)

  function refreshDisk() {
    if (!diskProc.running) diskProc.running = true
  }

  // ------------------------------------------------------------- panel hook
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }
  function rescan() {
    var target = panelLoader.item
    if (!target) return
    if (target.open) target.open()
    if (typeof target.startScan === "function") target.startScan()
  }

  // Open straight into one of the two halves — handy for a keybind, and the
  // only way to reach the uninstaller without clicking.
  function openSection(name) {
    var target = panelLoader.item
    if (!target) return
    if (target.open) target.open()
    if (typeof target.setSection === "function") target.setSection(name)
  }
  // The bar icon's own entry point: always the cleaner, whatever tab was last
  // on screen.
  function openClean() {
    var target = panelLoader.item
    if (!target) return
    if (target.open) target.open()
    if (typeof target.openClean === "function") target.openClean()
  }

  readonly property bool opened: panelLoader.item ? (panelLoader.item.opened === true) : false

  readonly property bool popoutSwitchClosing: panelLoader.item ? (panelLoader.item.popoutSwitchClosing === true) : false

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "nishant.tidy"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function scan(): void { root.rescan() }
    function clean(): void { root.openClean() }
    function uninstall(): void { root.openSection("apps") }
    function disk(): void { root.refreshDisk() }
  }

  Process {
    id: diskProc
    command: ["/usr/bin/python3", root.stateScript, "disk", "/"]
    stdout: StdioCollector {
      id: diskOut
      waitForEnd: true
    }
    onExited: function(code) {
      var text = String(diskOut.text || "").replace(/^\s+|\s+$/g, "")
      if (text.length === 0) return
      var data = null
      try {
        data = JSON.parse(text)
      } catch (error) {
        return
      }
      if (!data || !data.ok) return
      root.totalBytes = Number(data.total) || 0
      root.freeBytes = Number(data.free) || 0
    }
  }

  Timer {
    // A minute is often enough to notice a download finishing, and rare enough
    // that the read never shows up in anyone's power budget.
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDisk()
  }

  // The ring is drawn rather than assembled from rotated rectangles so the arc
  // stays smooth at this size. `requestPaint` is explicit because a Canvas has
  // no idea the numbers behind it moved.
  Component {
    id: gauge

    Item {
      anchors.fill: parent

      Canvas {
        id: ring
        anchors.fill: parent
        antialiasing: true

        readonly property real stroke: Math.max(1.5, Math.round(Math.min(width, height) * 0.11))

        Connections {
          target: root
          function onFreeBytesChanged() { ring.requestPaint() }
          function onTotalBytesChanged() { ring.requestPaint() }
        }

        onWidthChanged: ring.requestPaint()
        onHeightChanged: ring.requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          if (width <= 2 || height <= 2) return
          var cx = width / 2
          var cy = height / 2
          var radius = Math.min(width, height) / 2 - ring.stroke / 2 - 0.5
          if (radius <= 1) return

          ctx.lineWidth = ring.stroke
          ctx.lineCap = "round"

          ctx.strokeStyle = Util.alpha(root.fg, 0.20)
          ctx.beginPath()
          ctx.arc(cx, cy, radius, 0, Math.PI * 2)
          ctx.stroke()

          var fraction = root.usedFraction
          if (fraction > 0.004) {
            ctx.strokeStyle = root.low ? root.warning : root.accent
            ctx.beginPath()
            ctx.arc(cx, cy, radius, -Math.PI / 2, -Math.PI / 2 + fraction * Math.PI * 2)
            ctx.stroke()
          }
        }
      }

      Text {
        anchors.centerIn: parent
        text: "\uf1f8"
        color: root.low ? root.warning : root.fg
        font.family: Style.font.family
        font.pixelSize: Math.round(Math.min(parent.width, parent.height) * 0.42)
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf1f8"
    iconComponent: gauge
    tooltipText: root.tooltip
    onPressed: function(b) {
      // Opening from the bar always lands on the cleaner.
      if (!root.opened) root.openClean()
      else root.togglePanel()
    }
  }
}
