import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Tidy — a BleachBit-shaped system cleaner.
//
// Layout: header, reclaimable summary, toolbar, a grouped list of cleaners
// with checkboxes, a description strip for whatever the cursor is on, and a
// footer with the two real actions (Preview / Delete).
//
// Everything destructive goes through the shell scripts in scripts/: the
// QML never touches the filesystem itself, it only measures on open and then
// runs `tidy-clean` once per job. System cleaners are batched into a single
// job so the whole privileged pass costs exactly one polkit prompt.
Panel {
  id: root
  moduleName: "nishant.tidy"
  ipcTarget: "nishant.tidy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // ------------------------------------------------------------------ parts
  // The panel is loaded from the plugin directory, so the scripts sit next
  // to us. Resolving through Qt.resolvedUrl keeps this working whichever
  // directory OMARCHY_CONFIG_PATH points at.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.slice(7)
    url = decodeURIComponent(url)
    if (url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
    return url
  }
  readonly property string scanScript: root.pluginDir + "/scripts/tidy-scan"
  readonly property string cleanScript: root.pluginDir + "/scripts/tidy-clean"

  // ---------------------------------------------------------------- palette
  readonly property color fg: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Util.alpha(fg, 0.62)
  readonly property color faint: Util.alpha(fg, 0.38)
  readonly property color fill: Util.alpha(fg, 0.05)
  readonly property color stroke: Util.alpha(fg, 0.12)
  readonly property color success: "#3ecf72"
  readonly property color warning: "#f0a83c"
  readonly property color danger: "#ef5f5f"
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ------------------------------------------------------------------ shape
  readonly property int cardWidth: Style.space(432)
  readonly property int cardPadding: Style.spacing.popupPadding
  readonly property real groupRowH: Style.space(34)
  readonly property real cleanerRowH: Style.space(30)
  readonly property real rowIndent: Style.space(20)

  // ------------------------------------------------------------------ state
  // id -> { bytes, files, available, reason }. Filled by tidy-scan.
  property var scan: ({})
  property bool scanning: false
  property bool hasScanned: false
  property string scanError: ""

  property var checked: {
    var out = ({})
    for (var i = 0; i < Model.CLEANERS.length; i++)
      out[Model.CLEANERS[i].id] = Model.CLEANERS[i].defaultOn === true
    return out
  }
  property var expanded: ({ system: true, user: true, apps: true })

  // idle | confirm | running | done
  property string phase: "idle"
  property bool previewMode: false
  property bool shred: false
  // Set by the one-click button. It is not a selection, so it cannot be read
  // off the checkboxes — the backend owns the conservative set and this only
  // says "ask for that one".
  property bool safeRun: false

  property var jobs: []
  property int jobIndex: 0
  property var results: []
  property real freedBytes: 0
  property int freedFiles: 0
  property string runError: ""

  property int cursor: 0

  // clean | apps | space | history — four surfaces inside the same card.
  property string section: "clean"

  readonly property bool busy: root.phase === "running" || root.scanning
  readonly property bool overlayOpen: root.phase !== "idle"

  readonly property real jobProgress: root.jobs.length > 0
    ? Math.min(1, root.jobIndex / root.jobs.length)
    : 0

  readonly property bool hasSystemSelection: {
    var ids = root.selectedIds()
    for (var i = 0; i < ids.length; i++) {
      var cleaner = Model.byId(ids[i])
      if (cleaner && cleaner.kind === "system") return true
    }
    return false
  }

  // What the one-click button would free, from the scan that is already on
  // screen. Zero while the scan is still out, which the button reads as
  // "no number yet" rather than "nothing to do".
  readonly property real safeEstimate: Model.safeBytes(root.scan)

  // The conservative set as a row list, for the running overlay's detail line.
  readonly property var safeLabels: {
    var out = []
    var ids = Model.safeIds()
    for (var i = 0; i < ids.length; i++) {
      var cleaner = Model.byId(ids[i])
      if (cleaner) out.push(cleaner.label)
    }
    return out
  }

  // Runtime results in registry order, labelled for display.
  readonly property var resultRows: {
    var out = []
    for (var i = 0; i < Model.CLEANERS.length; i++) {
      var cleaner = Model.CLEANERS[i]
      for (var r = 0; r < root.results.length; r++) {
        var result = root.results[r]
        if (result.id !== cleaner.id) continue
        out.push({
          id: result.id,
          label: cleaner.label,
          status: result.status,
          bytes: result.bytes,
          files: result.files,
          message: result.message
        })
        break
      }
    }
    return out
  }

  // ------------------------------------------------------------------ rows
  // Flat list of the visible rows: a group header followed by its cleaners
  // when that group is expanded. Rebuilt whenever the expansion map changes.
  readonly property var rows: {
    var expandedMap = root.expanded
    var out = []
    for (var g = 0; g < Model.GROUPS.length; g++) {
      var group = Model.GROUPS[g]
      out.push({ type: "group", gid: group.id, group: group })
      if (expandedMap[group.id] === false) continue
      var kids = Model.cleanersIn(group.id)
      for (var k = 0; k < kids.length; k++)
        out.push({ type: "cleaner", gid: group.id, cleaner: kids[k] })
    }
    return out
  }

  onRowsChanged: {
    if (root.rows.length === 0) { root.cursor = 0; return }
    root.cursor = Math.max(0, Math.min(root.cursor, root.rows.length - 1))
  }

  readonly property var activeRow: root.rows[root.cursor] || null

  // ---------------------------------------------------------------- helpers
  function isChecked(id) {
    return root.checked[id] === true
  }

  function setChecked(id, value) {
    if (root.checked[id] === value) return
    var next = ({})
    for (var key in root.checked) next[key] = root.checked[key]
    next[id] = value
    root.checked = next
  }

  function toggleChecked(id) {
    root.setChecked(id, !root.isChecked(id))
  }

  function isExpanded(gid) {
    return root.expanded[gid] !== false
  }

  function toggleExpanded(gid) {
    var next = ({})
    for (var key in root.expanded) next[key] = root.expanded[key]
    next[gid] = !root.isExpanded(gid)
    root.expanded = next
  }

  function entryFor(id) {
    return root.scan[id] || null
  }

  function bytesFor(id) {
    var entry = root.entryFor(id)
    if (!entry || !entry.available) return 0
    return Number(entry.bytes) || 0
  }

  function sizeText(id, fallback) {
    if (root.scanning && !root.hasScanned) return "…"
    return Model.sizeLabel(root.entryFor(id), fallback)
  }

  // { total, on, available, bytes, onBytes }
  function groupStats(gid) {
    var kids = Model.cleanersIn(gid)
    var stats = { total: kids.length, on: 0, available: 0, bytes: 0, onBytes: 0 }
    for (var i = 0; i < kids.length; i++) {
      var id = kids[i].id
      var entry = root.entryFor(id)
      var available = !!(entry && entry.available)
      if (available) {
        stats.available++
        stats.bytes += Number(entry.bytes) || 0
      }
      if (root.isChecked(id)) {
        stats.on++
        if (available) stats.onBytes += Number(entry.bytes) || 0
      }
    }
    return stats
  }

  function groupChecked(gid) {
    return root.groupStats(gid).on === Model.cleanersIn(gid).length
  }

  function groupPartial(gid) {
    var stats = root.groupStats(gid)
    return stats.on > 0 && stats.on < stats.total
  }

  function selectedIds() {
    var out = []
    for (var i = 0; i < Model.CLEANERS.length; i++)
      if (root.isChecked(Model.CLEANERS[i].id)) out.push(Model.CLEANERS[i].id)
    return out
  }

  readonly property int selectedCount: {
    var n = 0
    for (var key in root.checked) if (root.checked[key] === true) n++
    return n
  }

  readonly property real selectedBytes: {
    var total = 0
    var ids = root.selectedIds()
    for (var i = 0; i < ids.length; i++) total += root.bytesFor(ids[i])
    return total
  }

  // Where the reclaimable space actually lives, per group, as fractions of
  // the selected total. Drives the segmented bar under the headline.
  readonly property var segments: {
    var total = root.selectedBytes
    if (!(total > 0)) return []
    var out = []
    var count = 0
    for (var g = 0; g < Model.GROUPS.length; g++) {
      var stats = root.groupStats(Model.GROUPS[g].id)
      if (!(stats.onBytes > 0)) continue
      count++
    }
    var index = 0
    for (var i = 0; i < Model.GROUPS.length; i++) {
      var st = root.groupStats(Model.GROUPS[i].id)
      if (!(st.onBytes > 0)) continue
      var fraction = st.onBytes / total
      // Earlier groups paint at full strength, later ones step down, so the
      // bands stay differentiable on any theme accent.
      var strength = 1.0 - ((count > 1 ? index / (count - 1) : 0) * 0.55)
      out.push({
        gid: Model.GROUPS[i].id,
        title: Model.GROUPS[i].title,
        label: Model.formatBytes(st.onBytes),
        fraction: fraction,
        strength: strength
      })
      index++
    }
    return out
  }

  function setAll(value) {
    var next = ({})
    for (var i = 0; i < Model.CLEANERS.length; i++)
      next[Model.CLEANERS[i].id] = value
    root.checked = next
  }

  function readableOn(color) {
    var r = color.r
    var g = color.g
    var b = color.b
    var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return lum > 0.62 ? "#101315" : "#ffffff"
  }

  function groupDesc(gid) {
    for (var i = 0; i < Model.GROUPS.length; i++)
      if (Model.GROUPS[i].id === gid) return Model.GROUPS[i].desc
    return ""
  }

  function rowOffset(index) {
    var y = 0
    for (var i = 0; i < index && i < root.rows.length; i++)
      y += root.rows[i].type === "group" ? root.groupRowH : root.cleanerRowH
    return y
  }

  function ensureVisible() {
    var y = root.rowOffset(root.cursor)
    var h = root.activeRow && root.activeRow.type === "group" ? root.groupRowH : root.cleanerRowH
    var view = listFlick.height
    var maxY = Math.max(0, listCol.height - view)
    if (y < listFlick.contentY) listFlick.contentY = Math.min(y, maxY)
    else if (y + h > listFlick.contentY + view) listFlick.contentY = Math.min(y + h - view, maxY)
  }

  // ---------------------------------------------------------------- actions
  function activateRow(index) {
    var row = root.rows[index]
    if (!row) return
    root.cursor = index
    if (row.type === "group") root.toggleExpanded(row.gid)
    else root.toggleChecked(row.cleaner.id)
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    root.cursor = Math.max(0, Math.min(root.cursor + delta, root.rows.length - 1))
    root.ensureVisible()
  }

  function buildJobs() {
    var user = []
    var system = []
    for (var i = 0; i < Model.CLEANERS.length; i++) {
      var cleaner = Model.CLEANERS[i]
      if (!root.isChecked(cleaner.id)) continue
      if (cleaner.kind === "system") system.push(cleaner.id)
      else user.push(cleaner.id)
    }
    var jobs = []
    for (var u = 0; u < user.length; u++)
      jobs.push({ ids: [user[u]], label: Model.byId(user[u]).label, system: false })
    if (system.length > 0) {
      var names = []
      for (var s = 0; s < system.length; s++) names.push(Model.byId(system[s]).label)
      jobs.push({ ids: system, label: "Administrator batch", detail: names.join(", "), system: true })
    }
    return jobs
  }

  function requestRun(preview) {
    if (root.busy) return
    if (root.selectedCount === 0) return
    root.safeRun = false
    root.previewMode = preview
    if (preview) root.startRun()
    else root.phase = "confirm"
  }

  // The one-click button. No checkboxes and no confirmation step: everything in
  // the conservative set is a cache, a thumbnail or the trash, so a gate would
  // only cost the user time. The backend owns the list — the UI asks for "the
  // safe set" rather than keeping a second copy of which cleaners that is.
  function requestSafeClean() {
    if (root.busy) return
    root.safeRun = true
    root.previewMode = false
    root.jobs = [{ ids: [], label: "Safe clean", detail: root.safeLabels.join(", "), system: false }]
    root.jobIndex = 0
    root.results = []
    root.freedBytes = 0
    root.freedFiles = 0
    root.runError = ""
    root.phase = "running"
    root.runJob()
  }

  function startRun() {
    root.jobs = root.buildJobs()
    root.jobIndex = 0
    root.results = []
    root.freedBytes = 0
    root.freedFiles = 0
    root.runError = ""
    root.phase = "running"
    root.runJob()
  }

  function runJob() {
    if (root.jobIndex >= root.jobs.length) {
      root.finishRun()
      return
    }
    var job = root.jobs[root.jobIndex]
    var argv = ["/usr/bin/bash", root.cleanScript]
    if (root.safeRun) {
      argv.push("--safe")
      // "You pressed the button" and "the timer ran last night" are different
      // facts; the history should not have to guess which one this was.
      argv.push("--as", "clean")
    }
    if (root.previewMode) argv.push("--preview")
    if (root.shred) argv.push("--shred")
    for (var i = 0; i < job.ids.length; i++) argv.push(job.ids[i])
    cleanProc.command = argv
    cleanProc.running = true
  }

  function parseResults(raw) {
    var lines = String(raw || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.indexOf("RESULT ") !== 0) continue
      var parts = line.split(" ")
      if (parts.length < 6) continue
      out.push({
        id: parts[1],
        status: parts[2],
        bytes: Number(parts[3]) || 0,
        files: Number(parts[4]) || 0,
        message: parts.slice(5).join(" ")
      })
    }
    return out
  }

  function jobFailed(raw, code) {
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (text.length > 0) return false
    if (code === 0) return false
    return true
  }

  function finishJob(raw, code) {
    if (root.jobFailed(raw, code))
      root.runError = "The cleaner exited with code " + code + "."

    var parsed = root.parseResults(raw)
    var merged = root.results.slice(0)
    for (var i = 0; i < parsed.length; i++) {
      var result = parsed[i]
      merged.push(result)
      if (result.status === "ok" || result.status === "preview") {
        root.freedBytes += result.bytes
        root.freedFiles += result.files
      }
    }
    root.results = merged
    root.jobIndex = root.jobIndex + 1
    Qt.callLater(root.runJob)
  }

  function finishRun() {
    root.phase = "done"
    if (!root.previewMode) root.startScan(true)
  }

  function dismissOverlay() {
    if (root.phase === "running") return
    root.phase = "idle"
    root.previewMode = false
    root.safeRun = false
  }

  // ---------------------------------------------------------------- scanning
  function setSection(next) {
    if (root.section === next) return
    // Only a cleaner that is actually running owns the panel. A mere scan
    // (which every open kicks off) must not block a section switch, or
    // `nishant.tidy uninstall` would land on Clean.
    if (root.phase === "running") return
    if (root.section === "apps" && appsView.overlayOpen) return
    root.section = next
    if (next === "apps") {
      appsView.start()
      appsView.focusList()
    } else {
      // Space and History measure on arrival rather than on open: a stale
      // free-space number is a lie, and the run log is only interesting once
      // you are looking at it.
      if (next === "space") spaceView.start()
      else if (next === "history") historyView.start()
      keyRoot.forceActiveFocus()
    }
  }

  // What the bar icon does. `section` outlives a close because the Panel is
  // built once and kept, so without this the next click to open would drop you
  // back into whichever tab you last looked at. The cleaner is the default
  // landing; the uninstaller is the deliberate choice (Tab, a click, or the
  // `uninstall` verb). A removal that is actually running is never yanked out
  // from under the user.
  function openClean() {
    if (appsView.phase === "running" || appsView.phase === "wiping") return
    if (appsView.overlayOpen) appsView.dismiss()
    root.section = "clean"
    keyRoot.forceActiveFocus()
  }

  function startScan(silent) {
    if (scanProc.running || cleanProc.running) return
    if (!silent) root.hasScanned = false
    root.scanning = true
    root.scanError = ""
    scanProc.running = true
  }

  function applyScan(raw) {
    root.scanning = false
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (text.length === 0) {
      root.scanError = "The scanner returned nothing."
      return
    }
    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      parsed = null
    }
    if (!parsed || !parsed.items) {
      root.scanError = "Could not read the scan result."
      return
    }
    root.scan = parsed.items
    root.hasScanned = true
    root.scanError = ""
  }

  Process {
    id: scanProc
    command: ["/usr/bin/bash", root.scanScript]
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function(code) {
      root.applyScan(scanOut.text)
      if (code !== 0 && root.scanError === "")
        root.scanError = "The scanner exited with code " + code + "."
    }
  }

  Process {
    id: cleanProc
    command: ["/usr/bin/bash", root.cleanScript]
    stdout: StdioCollector {
      id: cleanOut
      waitForEnd: true
    }
    onExited: function(code) {
      root.finishJob(cleanOut.text, code)
    }
  }

  onOpenedChanged: {
    if (root.opened) root.startScan(root.hasScanned)
  }

  // Keyboard is owned here rather than by PanelKeyCatcher: Space has to
  // toggle a checkbox while Enter runs the cleaner, and PanelKeyCatcher
  // fires both from a single Return.
  function handleKey(event) {
    if (event.key === Qt.Key_Tab) {
      // Four surfaces on one ring: Clean -> Uninstall -> Space -> History,
      // and back the other way with Shift.
      var ring = ["clean", "apps", "space", "history"]
      var step = (event.modifiers & Qt.ShiftModifier) ? -1 : 1
      var at = ring.indexOf(root.section)
      root.setSection(ring[(at + step + ring.length) % ring.length])
      event.accepted = true
      return
    }
    if (root.section === "apps") {
      appsView.handleKey(event)
      return
    }
    if (root.section === "space") {
      spaceView.handleKey(event)
      return
    }
    if (root.section === "history") {
      historyView.handleKey(event)
      return
    }
    if (root.phase === "confirm") {
      if (event.key === Qt.Key_Escape) {
        root.dismissOverlay()
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.startRun()
        event.accepted = true
        return
      }
      return
    }
    if (root.phase === "done") {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.dismissOverlay()
        event.accepted = true
        return
      }
      if (event.text === "r" || event.text === "R") {
        root.startScan(false)
        root.dismissOverlay()
        event.accepted = true
      }
      return
    }
    if (root.phase === "running") {
      // Not cancellable mid-flight: the privileged batch is already out.
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Escape) {
      root.close()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Down || event.text === "j") {
      root.moveCursor(1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Up || event.text === "k") {
      root.moveCursor(-1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_PageDown) {
      root.moveCursor(4)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_PageUp) {
      root.moveCursor(-4)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Space || event.text === "x" || event.text === "X") {
      root.activateRow(root.cursor)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.requestRun(false)
      event.accepted = true
      return
    }
    if (event.text === "p" || event.text === "P") {
      root.requestRun(true)
      event.accepted = true
      return
    }
    if (event.text === "a" || event.text === "A") {
      root.setAll(true)
      event.accepted = true
      return
    }
    if (event.text === "n" || event.text === "N") {
      root.setAll(false)
      event.accepted = true
      return
    }
    if (event.text === "s" || event.text === "S") {
      root.requestSafeClean()
      event.accepted = true
      return
    }
    if (event.text === "r" || event.text === "R") {
      root.startScan(false)
      event.accepted = true
    }
  }

  // Thin scroll affordance for the Flickables. Lives inside the flickable so
  // it sits above the content, but compensates for contentY to stay put.
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
    color: Util.alpha(root.fg, 0.20)
    x: knob.flick.width - knob.width - Style.space(1)
    y: knob.flick.contentY + (knob.flick.height - knob.height)
      * (knob.flick.contentY / knob.span)
  }

  // ------------------------------------------------------------ inline parts
  // Tri-state checkbox. Row clicks own the toggle; this only paints.
  component Tick: Item {
    id: tick
    property bool checked: false
    property bool partial: false
    property bool dimmed: false
    property bool hasCursor: false
    property color tone: root.accent

    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
      color: (tick.checked || tick.partial) ? tick.tone : "transparent"
      border.width: Math.max(1, Style.space(1))
      border.color: (tick.checked || tick.partial)
        ? tick.tone
        : Util.alpha(root.fg, tick.hasCursor ? 0.72 : 0.36)
      opacity: tick.dimmed ? 0.35 : 1.0

      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    Text {
      anchors.centerIn: parent
      visible: tick.checked || tick.partial
      text: tick.partial && !tick.checked ? "\uf068" : "\uf00c"
      color: root.readableOn(tick.tone)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      opacity: tick.dimmed ? 0.5 : 1.0
    }
  }

  // Solid accent button. The kit's Button has no disabled state and always
  // paints its own state fills, so the one button that must be able to go
  // inert is drawn here instead.
  component FilledButton: Rectangle {
    id: action
    property string text: ""
    property string iconText: ""
    property bool disabled: false
    property bool destructive: false
    property color tone: root.accent
    signal clicked()

    readonly property color base: action.destructive ? root.danger : action.tone
    readonly property bool hot: actionArea.containsMouse && !action.disabled

    implicitWidth: label.implicitWidth + Style.space(30)
    implicitHeight: Style.space(32)
    radius: Style.cornerRadius
    color: action.disabled ? Util.alpha(root.fg, 0.07)
      : actionArea.pressed ? Qt.darker(action.base, 1.18)
      : action.hot ? Qt.lighter(action.base, 1.10)
      : action.base
    border.width: Math.max(1, Style.space(1))
    border.color: action.disabled ? Util.alpha(root.fg, 0.10) : "transparent"

    Behavior on color { ColorAnimation { duration: 110 } }

    Text {
      id: label
      anchors.centerIn: parent
      text: (action.iconText !== "" ? action.iconText + "  " : "") + action.text
      color: action.disabled ? root.faint : root.readableOn(action.base)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: actionArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: !action.disabled
      cursorShape: action.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root
    open: root.opened
    padding: root.cardPadding
    contentWidth: popup.fittedContentWidth(root.cardWidth)
    contentHeight: popup.fittedContentHeight(keyRoot.height)
    focusTarget: keyRoot

    Item {
      id: keyRoot
      width: parent.width
      height: body.implicitHeight
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { root.handleKey(event) }

      // Overlay result lists get whatever the card has left after their own
      // heading/copy/buttons, so a full cleaner list is visible without
      // guessing a fixed cap.
      readonly property real overlayListMaxHeight: Math.max(Style.space(120),
        keyRoot.height - Style.space(170))

      Column {
        id: body
        width: parent.width
        spacing: Style.space(10)

        // Everything except the list. Used to size the list so the card
        // fits the screen rather than being clipped by the popup.
        readonly property real chromeHeight: headerRow.height + sectionTabs.height
          + summaryCard.height + toolbarRow.height + sepA.height + sepB.height
          + infoCard.height + footerRow.height + spacing * 8

        // ============================ Header ==============================
        Item {
          id: headerRow
          width: body.width
          height: Math.max(headerTile.height, headerText.implicitHeight)

          Rectangle {
            id: headerTile
            width: Style.space(38)
            height: Style.space(38)
            radius: Style.cornerRadius
            color: Util.alpha(root.accent, 0.16)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(root.accent, 0.34)

            Text {
              anchors.centerIn: parent
              text: "\uf1f8"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }

          Column {
            id: headerText
            anchors.left: headerTile.right
            anchors.leftMargin: Style.space(11)
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              text: "Tidy"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.scanning ? "Measuring what can be reclaimed…"
                : root.scanError !== "" ? root.scanError
                : root.hasScanned ? "Free space without breaking anything"
                : "Ready when you are"
              color: root.scanError !== "" ? root.danger : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf021"
            tooltipText: "Rescan"
            foreground: root.fg
            hoverColor: root.accent
            hasCursor: false
            onClicked: root.startScan(false)
          }
        }

        // ============================ Sections ============================
        Row {
          id: sectionTabs
          width: body.width
          spacing: Style.spacing.controlGap

          Repeater {
            model: [
              { tab: "clean", label: "Clean", glyph: "\uf1f8" },
              { tab: "apps", label: "Uninstall", glyph: "\uf187" },
              { tab: "space", label: "Space", glyph: "\uf1c0" },
              { tab: "history", label: "History", glyph: "\uf1da" },
            ]

            delegate: Button {
              required property var modelData
              text: modelData.label
              iconText: modelData.glyph
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              selected: root.section === modelData.tab
              focusable: false
              onClicked: root.setSection(modelData.tab)
            }
          }
        }

        // ============================ Summary =============================
        Rectangle {
          id: summaryCard
          visible: root.section === "clean"
          width: body.width
          height: summary.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Util.alpha(root.fg, 0.045)
          border.width: Math.max(1, Style.space(1))
          border.color: Util.alpha(root.fg, 0.10)

          Column {
            id: summary
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(7)

            Item {
              width: parent.width
              height: Math.max(headline.implicitHeight, shareLabel.implicitHeight)

              Text {
                id: headline
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.scanning && !root.hasScanned
                  ? "…"
                  : Model.formatBytes(root.selectedBytes)
                color: root.selectedBytes > 0 ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Text {
                id: shareLabel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "reclaimable"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              text: root.selectedCount + " of " + Model.CLEANERS.length + " cleaners selected"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Item {
              id: segBar
              width: parent.width
              height: Style.space(6)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
                color: Util.alpha(root.fg, 0.09)
              }

              Repeater {
                model: root.segments

                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  readonly property real gap: Style.space(2)
                  readonly property real usable: segBar.width
                    - segBar.gap * Math.max(0, root.segments.length - 1)
                  x: {
                    var offset = 0
                    for (var i = 0; i < index; i++)
                      offset += root.segments[i].fraction
                    return Math.round(offset * usable + index * segBar.gap)
                  }
                  width: Math.max(2, Math.round(modelData.fraction * usable))
                  height: segBar.height
                  radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
                  color: Util.alpha(root.accent, modelData.strength)
                }
              }
            }
          }
        }

        // ============================ Toolbar =============================
        Item {
          id: toolbarRow
          visible: root.section === "clean"
          width: body.width
          height: Math.max(allButton.height, Math.max(shredButton.height, safeButton.height))

          Button {
            id: allButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "All"
            foreground: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            bordered: true
            focusable: false
            onClicked: root.setAll(true)
          }

          Button {
            id: noneButton
            anchors.left: allButton.right
            anchors.leftMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            text: "None"
            foreground: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            bordered: true
            focusable: false
            onClicked: root.setAll(false)
          }

          // The one-click path. It sits in the corner the eye lands on last
          // and the thumb lands on first, it names what it will free, and it
          // does not ask twice — the set behind it is only caches.
          FilledButton {
            id: safeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf0e7"
            text: {
              if (root.safeEstimate <= 0) return "Safe clean"
              return "Safe clean " + Model.formatBytes(root.safeEstimate)
            }
            disabled: root.busy
            onClicked: root.requestSafeClean()
          }

          Button {
            id: shredButton
            anchors.right: safeButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            text: "Overwrite"
            iconText: "\uf132"
            tooltipText: "Overwrite files with random data before deleting them. Slower, and only applies to your own files."
            foreground: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            selected: root.shred
            focusable: false
            onClicked: root.shred = !root.shred
          }
        }

        PanelSeparator {
          id: sepA
          visible: root.section === "clean"
          foreground: root.fg
        }

        // ============================ List ================================
        Flickable {
          id: listFlick
          visible: root.section === "clean"
          width: body.width
          // Fill whatever the card has left after the fixed chrome, so the
          // panel always fits the screen instead of being clipped.
          height: Math.max(Style.space(150),
            popup.availableCardHeight - popup.verticalContentInset - body.chromeHeight)
          contentWidth: width
          contentHeight: listCol.height
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listCol
            width: listFlick.width

            Repeater {
              model: root.rows

              delegate: Item {
                id: rowItem
                required property var modelData
                required property int index

                readonly property bool isGroup: modelData.type === "group"
                readonly property bool hasCursor: root.cursor === index
                readonly property bool hot: rowArea.containsMouse
                readonly property var stats: isGroup ? root.groupStats(modelData.gid) : null
                readonly property string targetId: isGroup ? "" : modelData.cleaner.id

                width: listCol.width
                height: isGroup ? root.groupRowH : root.cleanerRowH

                Rectangle {
                  anchors.fill: parent
                  anchors.rightMargin: Style.space(2)
                  anchors.leftMargin: Style.space(2)
                  radius: Style.cornerRadius
                  color: rowItem.hasCursor ? Util.alpha(root.accent, 0.16)
                    : rowItem.hot ? Util.alpha(root.fg, 0.06)
                    : "transparent"
                  border.width: rowItem.hasCursor ? Math.max(1, Style.space(1)) : 0
                  border.color: Util.alpha(root.accent, 0.45)

                  Behavior on color { ColorAnimation { duration: 110 } }
                }

                Tick {
                  id: rowTick
                  anchors.left: parent.left
                  anchors.leftMargin: rowItem.isGroup ? Style.space(9) : Style.space(9) + root.rowIndent
                  anchors.verticalCenter: parent.verticalCenter
                  hasCursor: rowItem.hasCursor
                  checked: rowItem.isGroup
                    ? root.groupChecked(rowItem.modelData.gid)
                    : root.isChecked(rowItem.targetId)
                  partial: rowItem.isGroup ? root.groupPartial(rowItem.modelData.gid) : false
                  dimmed: !rowItem.isGroup
                    && !(root.entryFor(rowItem.targetId) || { available: 1 }).available
                }

                Text {
                  id: rowGlyph
                  anchors.left: rowTick.right
                  anchors.leftMargin: Style.space(9)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter
                  text: rowItem.isGroup ? modelData.group.glyph : modelData.cleaner.glyph
                  color: rowItem.isGroup ? root.dim : (rowItem.hasCursor ? root.fg : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: rowItem.isGroup ? Style.font.icon : Style.font.body
                }

                Text {
                  id: rowLabel
                  anchors.left: rowGlyph.right
                  anchors.leftMargin: Style.space(6)
                  anchors.right: rowRight.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowItem.isGroup
                    ? modelData.group.title.toUpperCase()
                    : modelData.cleaner.label
                  color: rowItem.isGroup ? root.faint : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: rowItem.isGroup ? Style.font.caption : Style.font.body
                  font.bold: rowItem.isGroup
                  font.letterSpacing: rowItem.isGroup ? Style.space(1) : 0
                  elide: Text.ElideRight
                }

                Item {
                  id: rowRight
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  width: rowChevron.visible
                    ? rowSize.implicitWidth + Style.space(8) + rowChevron.implicitWidth
                    : rowSize.implicitWidth
                  height: Math.max(rowSize.implicitHeight, rowChevron.visible ? rowChevron.implicitHeight : 0)

                  Text {
                    id: rowSize
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: rowItem.isGroup
                      ? Model.formatBytes(rowItem.stats.onBytes)
                      : root.sizeText(rowItem.targetId, false)
                    color: rowItem.isGroup ? root.dim : root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: rowChevron
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: rowItem.isGroup
                    text: root.isExpanded(rowItem.modelData.gid) ? "\uf078" : "\uf054"
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: rowArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activateRow(index)
                }
              }
            }
          }

          ScrollKnob { flick: listFlick }
        }

        PanelSeparator {
          id: sepB
          visible: root.section === "clean"
          foreground: root.fg
        }

        // ========================= Description ============================
        Rectangle {
          id: infoCard
          visible: root.section === "clean"
          width: body.width
          height: infoCol.implicitHeight + Style.space(18)
          radius: Style.cornerRadius
          color: Util.alpha(root.fg, 0.035)
          border.width: Math.max(1, Style.space(1))
          border.color: Util.alpha(root.fg, 0.08)

          Column {
            id: infoCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(9)
            spacing: Style.space(3)

            Item {
              width: parent.width
              height: Math.max(infoLabel.implicitHeight, adminBadge.height)

              Text {
                id: infoLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: {
                  var row = root.activeRow
                  if (!row) return "Nothing selected"
                  return row.type === "group" ? row.group.title : row.cleaner.label
                }
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Rectangle {
                id: adminBadge
                anchors.left: infoLabel.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: {
                  var row = root.activeRow
                  if (!row) return false
                  return row.type === "group"
                    ? row.gid === "system"
                    : row.cleaner.kind === "system"
                }
                width: adminText.implicitWidth + Style.space(10)
                height: adminText.implicitHeight + Style.space(4)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Util.alpha(root.warning, 0.20)
                border.width: Math.max(1, Style.space(1))
                border.color: Util.alpha(root.warning, 0.45)

                Text {
                  id: adminText
                  anchors.centerIn: parent
                  text: "ADMIN"
                  color: root.warning
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: Style.space(1)
                }
              }
            }

            Text {
              width: parent.width
              text: {
                var row = root.activeRow
                if (!row) return ""
                return row.type === "group" ? row.group.desc : row.cleaner.desc
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }

        // ============================ Footer ==============================
        Item {
          id: footerRow
          visible: root.section === "clean"
          width: body.width
          height: Math.max(deleteButton.height, hintText.implicitHeight)

          Text {
            id: hintText
            anchors.left: parent.left
            anchors.right: footerActions.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: root.shred ? "Overwrite is on · files are wiped before removal"
              : "Space toggles · s safe clean · Enter deletes · Tab switches tab"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Item {
            id: footerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Button {
              id: previewButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Preview"
              iconText: "\uf06e"
              tooltipText: "Dry run — measure what a clean would free without deleting anything."
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              bordered: true
              focusable: false
              onClicked: root.requestRun(true)
            }

            FilledButton {
              id: deleteButton
              anchors.left: previewButton.right
              anchors.leftMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              destructive: !root.previewMode
              disabled: root.selectedCount === 0 || root.busy
              iconText: "\uf1f8"
              text: root.selectedCount === 0
                ? "Delete"
                : "Delete " + Model.formatBytes(root.selectedBytes)
              onClicked: root.requestRun(false)
            }

            readonly property real leftEdge: previewButton.x
            width: deleteButton.x + deleteButton.width - leftEdge
          }
        }

        // ========================== Uninstall =============================
        UninstallView {
          id: appsView
          visible: root.section === "apps"
          width: body.width
          pluginDir: root.pluginDir
          fg: root.fg
          accent: root.accent
          dim: root.dim
          faint: root.faint
          danger: root.danger
          success: root.success
          warning: root.warning
          fontFamily: root.fontFamily
          keyTarget: keyRoot
          // Whatever the card has left once the header and the section tabs
          // have taken their share. The view measures its own chrome and gives
          // the list the remainder, so nothing — least of all the Uninstall
          // button — spills below the bottom edge of the card.
          maxHeight: Math.max(Style.space(240), popup.availableCardHeight
            - popup.verticalContentInset - headerRow.height - sectionTabs.height
            - body.spacing * 2)
          onRequestClose: root.close()
        }

        // ============================= Space ==============================
        SpaceView {
          id: spaceView
          visible: root.section === "space"
          width: body.width
          pluginDir: root.pluginDir
          fg: root.fg
          accent: root.accent
          dim: root.dim
          faint: root.faint
          danger: root.danger
          success: root.success
          warning: root.warning
          fontFamily: root.fontFamily
          keyTarget: keyRoot
          maxHeight: Math.max(Style.space(240), popup.availableCardHeight
            - popup.verticalContentInset - headerRow.height - sectionTabs.height
            - body.spacing * 2)
        }

        // ============================ History =============================
        HistoryView {
          id: historyView
          visible: root.section === "history"
          width: body.width
          pluginDir: root.pluginDir
          fg: root.fg
          accent: root.accent
          dim: root.dim
          faint: root.faint
          fill: root.fill
          stroke: root.stroke
          danger: root.danger
          success: root.success
          warning: root.warning
          fontFamily: root.fontFamily
          keyTarget: keyRoot
          maxHeight: Math.max(Style.space(240), popup.availableCardHeight
            - popup.verticalContentInset - headerRow.height - sectionTabs.height
            - body.spacing * 2)
        }
      }

      // ------------------------------------------------------- overlays
      // Confirm / running / done share one full-card panel so the surface
      // never resizes mid-operation.
      Rectangle {
        anchors.fill: parent
        visible: root.overlayOpen
        color: Commons.Color.popups.background

        MouseArea { anchors.fill: parent }

        // ---- confirm -------------------------------------------------------
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(20)
          spacing: Style.space(12)
          visible: root.phase === "confirm"

          Text {
            width: parent.width
            text: "Delete " + Model.formatBytes(root.selectedBytes) + "?"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.selectedCount + " cleaner" + (root.selectedCount === 1 ? "" : "s")
              + " will run. This cannot be undone."
              + (root.shred ? "  Files are overwritten with random data first." : "")
              + (root.hasSystemSelection ? "  Your password is requested once for the system files." : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Flickable {
            id: confirmFlick
            width: parent.width
            height: Math.min(confirmCol.height, keyRoot.overlayListMaxHeight)
            contentHeight: confirmCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: confirmCol
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.selectedIds()

                delegate: Item {
                  required property var modelData
                  width: confirmCol.width
                  height: Style.space(22)

                  Text {
                    anchors.left: parent.left
                    anchors.right: confirmSize.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.byId(modelData).label
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    id: confirmSize
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.sizeText(modelData, false)
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }

            ScrollKnob { flick: confirmFlick }
          }

          Item {
            width: parent.width
            height: Math.max(cancelButton.height, confirmButton.height)

            Button {
              id: cancelButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Cancel"
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              bordered: true
              focusable: false
              onClicked: root.dismissOverlay()
            }

            FilledButton {
              id: confirmButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              destructive: true
              iconText: "\uf1f8"
              text: "Delete"
              onClicked: root.startRun()
            }
          }
        }

        // ---- running -------------------------------------------------------
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(20)
          spacing: Style.space(12)
          visible: root.phase === "running"

          Text {
            width: parent.width
            text: root.previewMode ? "Measuring…" : "Cleaning…"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            width: parent.width
            text: {
              var job = root.jobs[root.jobIndex]
              if (!job) return "Finishing up"
              return job.detail ? job.label + " · " + job.detail : job.label
            }
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Item {
            width: parent.width
            height: Style.space(6)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
              color: Util.alpha(root.fg, 0.10)
            }

            Rectangle {
              width: Math.max(0, parent.width * root.jobProgress)
              height: parent.height
              radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
              color: root.accent

              Behavior on width {
                NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
              }
            }
          }

          Text {
            width: parent.width
            text: {
              var job = root.jobs[root.jobIndex]
              var step = "Step " + Math.min(root.jobIndex + 1, root.jobs.length) + " of " + root.jobs.length
              if (job && job.system && !root.previewMode)
                return step + " — approve the password prompt to continue"
              return step
            }
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        // ---- done ----------------------------------------------------------
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(20)
          spacing: Style.space(10)
          visible: root.phase === "done"

          Text {
            width: parent.width
            text: (root.previewMode ? "Would free " : "Freed ") + Model.formatBytes(root.freedBytes)
            color: root.previewMode ? root.fg : root.success
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            width: parent.width
            text: {
              var ok = 0
              var skipped = 0
              var failed = 0
              for (var i = 0; i < root.results.length; i++) {
                var status = root.results[i].status
                if (status === "ok" || status === "preview") ok++
                else if (status === "skip") skipped++
                else failed++
              }
              var parts = [ok + " cleaned"]
              if (skipped > 0) parts.push(skipped + " skipped")
              if (failed > 0) parts.push(failed + " failed")
              if (root.runError !== "") parts.push(root.runError)
              return parts.join(" · ")
            }
            color: root.runError !== "" ? root.danger : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Flickable {
            id: doneFlick
            width: parent.width
            height: Math.min(doneCol.height, keyRoot.overlayListMaxHeight)
            contentHeight: doneCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: doneCol
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.resultRows

                delegate: Item {
                  required property var modelData
                  width: doneCol.width
                  height: Style.space(22)

                  Text {
                    id: resultGlyph
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData.status === "ok" ? "\uf00c"
                      : modelData.status === "preview" ? "\uf06e"
                      : modelData.status === "skip" ? "\uf05e"
                      : "\uf00d"
                    color: modelData.status === "ok" ? root.success
                      : modelData.status === "preview" ? root.accent
                      : modelData.status === "skip" ? root.faint
                      : root.danger
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    anchors.left: resultGlyph.right
                    anchors.leftMargin: Style.space(6)
                    anchors.right: resultValue.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    id: resultValue
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: (modelData.status === "ok" || modelData.status === "preview")
                      ? Model.formatBytes(modelData.bytes)
                      : modelData.message
                    color: (modelData.status === "ok" || modelData.status === "preview") ? root.faint : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
              }
            }

            ScrollKnob { flick: doneFlick }
          }

          Item {
            width: parent.width
            height: Math.max(rescanButton.height, doneButton.height)

            Button {
              id: rescanButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Rescan"
              iconText: "\uf021"
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              bordered: true
              focusable: false
              onClicked: {
                root.dismissOverlay()
                root.startScan(false)
              }
            }

            FilledButton {
              id: doneButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf00c"
              text: "Done"
              onClicked: root.dismissOverlay()
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- derived
}
