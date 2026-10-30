import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// History — what Tidy has already done, and the three standing decisions that
// shape what it does next.
//
// A cleaner without memory is a thing you have to re-reason about every time
// you open it. This tab holds the running total, the individual runs, the
// restore points the uninstaller kept, the folders the cleaner has been told
// to leave alone, and the switch for the background job. It is the only place
// where "4.6 GB" is attached to a date.
//
// Interaction model matches the rest of the panel: a single cursor over the
// rows that can be acted on — the auto-clean switch, the restore points, the
// ignored folders — with Enter as the verb. The run log below is read-only, so
// it is deliberately not part of the cursor.
Item {
  id: view

  // -------------------------------------------------------------- injected
  property string pluginDir: ""
  property color fg: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  property color dim: Util.alpha(Commons.Color.popups.text, 0.62)
  property color faint: Util.alpha(Commons.Color.popups.text, 0.38)
  property color fill: Util.alpha(Commons.Color.popups.text, 0.05)
  property color stroke: Util.alpha(Commons.Color.popups.text, 0.12)
  property color success: "#3ecf72"
  property color warning: "#f0a83c"
  property color danger: "#ef5f5f"
  property string fontFamily: Style.font.family
  property real maxHeight: Style.space(420)
  property Item keyTarget: null

  // ----------------------------------------------------------------- state
  property var runs: []
  property int runCount: 0
  property real totalBytes: 0
  property var undo: []
  property var ignored: []
  property var schedule: ({})
  property bool loading: false
  property bool loaded: false
  property int cursor: 0
  property string notice: ""
  property string error: ""
  // The half-pressed key. Anything that costs more than a keystroke to undo —
  // putting a package back, throwing away a restore point, clearing the log —
  // needs the same key twice, which is cheap to do and impossible to do by
  // accident.
  property string armed: ""

  readonly property string stateScript: view.pluginDir + "/scripts/tidy-state"
  readonly property string schedScript: view.pluginDir + "/scripts/tidy-schedule"
  readonly property string python: "/usr/bin/python3"

  // Cursor rows: the switch first, then the things that can be removed.
  readonly property var rows: {
    var out = [{ kind: "auto", key: "auto" }]
    for (var i = 0; i < view.undo.length; i++) {
      var entry = view.undo[i]
      out.push({
        kind: "undo",
        key: "undo:" + entry.at,
        at: entry.at,
        name: entry.name || entry.id || "an application",
        source: entry.source || "",
        bytes: entry.archiveBytes || 0,
        available: entry.available !== false,
      })
    }
    for (var j = 0; j < view.ignored.length; j++)
      out.push({ kind: "ignore", key: "ignore:" + view.ignored[j], path: view.ignored[j] })
    return out
  }

  readonly property int undoBase: 1
  readonly property int ignoreBase: 1 + view.undo.length
  readonly property var current: view.rows.length === 0
    ? null
    : view.rows[Math.max(0, Math.min(view.cursor, view.rows.length - 1))]

  readonly property bool available: view.schedule.available === true
  readonly property bool enabled: view.schedule.enabled === true
  readonly property bool stale: view.schedule.stale === true
  readonly property string cadence: view.schedule.cadence === "daily" ? "daily" : "weekly"

  function indexOfKey(key) {
    for (var i = 0; i < view.rows.length; i++)
      if (view.rows[i].key === key) return i
    return -1
  }

  // Rows hand back their own geometry as they are built, so scrolling to the
  // cursor never has to guess a row height. Not reactive on purpose: this is
  // read on demand, never bound to.
  property var rowItems: ({})
  function registerRow(index, item) {
    view.rowItems[index] = item
  }

  // Rows are rebuilt whenever the undo or ignore lists change, and a geometry
  // cache of rows that have since been destroyed is worse than no cache —
  // ensureVisible would call mapToItem on a dead item — so the cache is
  // cleared wholesale on every rebuild and the surviving rows repopulate it.
  onRowsChanged: view.rowItems = ({})

  // ------------------------------------------------------------ formatting
  function when(epoch) {
    var at = Number(epoch) || 0
    if (at <= 0) return "never"
    var date = new Date(at * 1000)
    var diff = (Date.now() - date.getTime()) / 1000
    if (diff < 0) return "just now"
    if (diff < 90) return "just now"
    // Clamped to the top of each unit: rounding alone would print "60 min ago"
    // for a run that is about to become "1 h ago", so the header and the row
    // describing the same run could disagree about what to call it.
    if (diff < 3600) return Math.min(59, Math.round(diff / 60)) + " min ago"
    if (diff < 86400) return Math.min(23, Math.round(diff / 3600)) + " h ago"
    if (diff < 86400 * 7) return Math.min(6, Math.round(diff / 86400)) + " d ago"
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return months[date.getMonth()] + " " + date.getDate()
  }

  // "Mon 2026-10-26 00:07:40 IST" -> "Mon 2026-10-26 00:07"
  function tidyStamp(value) {
    var text = String(value || "")
    if (text === "") return ""
    var parts = text.split(" ")
    if (parts.length >= 3 && parts[2].indexOf(":") > 0)
      return parts[0] + " " + parts[1] + " " + parts[2].slice(0, 5)
    return text
  }

  function modeLabel(mode) {
    if (mode === "auto") return "Scheduled clean"
    if (mode === "uninstall") return "Uninstall"
    return "Clean"
  }

  // The one line that answers "what has this thing ever done for me".
  function headline() {
    if (!view.loaded) return "Reading the log…"
    if (view.runCount === 0) return "Nothing cleaned yet"
    return "Freed " + Model.formatBytes(view.totalBytes) + " across "
      + view.runCount + (view.runCount === 1 ? " run" : " runs")
  }

  function subline() {
    if (view.runCount === 0) return "Every run lands here, with what it freed and when."
    var newest = view.runs.length > 0 ? view.runs[0] : null
    return newest ? "Last run " + view.when(newest.at) : ""
  }

  // ------------------------------------------------------------ lifecycle
  function start() {
    if (schedProc.running || histProc.running || undoProc.running || ignoreProc.running) return
    view.loading = true
    view.notice = ""
    view.error = ""
    view.armed = ""
    histProc.running = true
    undoProc.running = true
    ignoreProc.running = true
    schedProc.running = true
  }

  function refresh() {
    view.start()
  }

  function moveCursor(delta) {
    if (view.rows.length === 0) return
    view.cursor = Math.max(0, Math.min(view.rows.length - 1, view.cursor + delta))
    listFlick.ensureVisible(view.cursor)
  }

  function jumpTo(key) {
    var index = view.indexOfKey(key)
    if (index < 0) return
    view.cursor = index
    listFlick.ensureVisible(index)
  }

  // --------------------------------------------------------------- actions
  function setCadence(value) {
    if (!view.available) return
    view.notice = ""
    if (view.enabled) {
      scheduleAct.command = ["/usr/bin/bash", view.schedScript, "enable", value]
      scheduleAct.running = true
    } else {
      // Nothing to talk to yet; remember the choice so turning the switch on
      // uses it.
      var next = JSON.parse(JSON.stringify(view.schedule))
      next.cadence = value
      view.schedule = next
      view.notice = "Auto-clean will run " + value + "."
    }
  }

  function toggleSchedule() {
    if (!view.available) {
      view.error = view.schedule.error
        ? String(view.schedule.error)
        : "No systemd user session to schedule into."
      return
    }
    view.notice = ""
    if (view.enabled) {
      scheduleAct.command = ["/usr/bin/bash", view.schedScript, "disable"]
    } else {
      scheduleAct.command = ["/usr/bin/bash", view.schedScript, "enable", view.cadence]
    }
    scheduleAct.running = true
  }

  function restorePicked() {
    var row = view.current
    if (!row || row.kind !== "undo") {
      view.jumpTo("undo:" + (view.undo.length > 0 ? view.undo[0].at : 0))
      return
    }
    if (!row.available) {
      view.error = "The backup for " + row.name + " is gone."
      return
    }
    if (view.armed !== row.key) {
      view.armed = row.key
      view.notice = "Press Enter again to put " + row.name + " back."
      armTimer.restart()
      return
    }
    view.armed = ""
    view.notice = "Putting " + row.name + " back…"
    undoAct.command = [view.python, view.stateScript, "undo-restore", String(row.at)]
    undoAct.running = true
  }

  function dropPicked() {
    var row = view.current
    if (!row) return
    if (row.kind === "undo") {
      if (view.armed !== row.key) {
        view.armed = row.key
        view.notice = "Press x again to throw away the backup of " + row.name + "."
        armTimer.restart()
        return
      }
      view.armed = ""
      undoAct.command = [view.python, view.stateScript, "undo-drop", String(row.at)]
      undoAct.running = true
      return
    }
    if (row.kind === "ignore") {
      view.notice = "Tidy may clean " + view.shortPath(row.path) + " again."
      ignoreAct.command = [view.python, view.stateScript, "ignore-del", row.path]
      ignoreAct.running = true
    }
  }

  function clearLog() {
    if (view.runCount === 0) return
    if (view.armed !== "clear") {
      view.armed = "clear"
      view.notice = "Press h again to clear the " + view.runCount + "-run log. Restore points are kept."
      armTimer.restart()
      return
    }
    view.armed = ""
    histAct.command = [view.python, view.stateScript, "history-clear"]
    histAct.running = true
  }

  function shortPath(value) {
    var text = String(value || "")
    // The home prefix is noise on every single row.
    return text.replace(/^\/(?:home|Users)\/[^/]+/, "~")
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (view.armed !== "") {
        view.armed = ""
        view.notice = ""
        event.accepted = true
      }
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
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      var row = view.current
      if (!row) return
      if (row.kind === "auto") view.toggleSchedule()
      else if (row.kind === "undo") view.restorePicked()
      else view.dropPicked()
      event.accepted = true
      return
    }
    if (event.text === "d" || event.text === "D") {
      var picked = view.current
      if (picked && picked.kind === "auto") view.setCadence(view.cadence === "daily" ? "weekly" : "daily")
      else view.dropPicked()
      event.accepted = true
      return
    }
    if (event.text === "x" || event.text === "X" || event.key === Qt.Key_Delete) {
      view.dropPicked()
      event.accepted = true
      return
    }
    if (event.text === "h" || event.text === "H") {
      view.clearLog()
      event.accepted = true
      return
    }
    if (event.text === "r" || event.text === "R") {
      view.refresh()
      event.accepted = true
    }
  }

  // -------------------------------------------------------------- processes
  Process {
    id: histProc
    command: [view.python, view.stateScript, "history", "--limit", "40"]
    stdout: StdioCollector {
      id: histOut
      waitForEnd: true
    }
    onExited: {
      var data = view.parse(histOut.text)
      if (data && data.ok) {
        view.runs = data.entries || []
        view.runCount = Number(data.runs) || 0
        view.totalBytes = Number(data.totalBytes) || 0
      }
      view.loaded = true
      view.loading = false
    }
  }

  Process {
    id: undoProc
    command: [view.python, view.stateScript, "undo-list"]
    stdout: StdioCollector {
      id: undoOut
      waitForEnd: true
    }
    onExited: {
      var data = view.parse(undoOut.text)
      if (data && data.ok) view.undo = data.entries || []
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
      var data = view.parse(ignoreOut.text)
      if (data && data.ok) view.ignored = data.paths || []
    }
  }

  Process {
    id: schedProc
    command: ["/usr/bin/bash", view.schedScript, "status"]
    stdout: StdioCollector {
      id: schedOut
      waitForEnd: true
    }
    onExited: {
      var data = view.parse(schedOut.text)
      if (data) view.schedule = data
    }
  }

  Process {
    id: scheduleAct
    stdout: StdioCollector {
      id: scheduleOut
      waitForEnd: true
    }
    onExited: function(code) {
      var data = view.parse(scheduleOut.text)
      if (data && data.ok) {
        view.schedule = data
        view.notice = data.enabled
          ? "Auto-clean is on — " + data.cadence + " in the background."
          : "Auto-clean is off."
        view.error = ""
      } else {
        view.error = data && data.error ? String(data.error)
          : "Could not change the schedule (exit " + code + ")."
      }
    }
  }

  Process {
    id: undoAct
    stdout: StdioCollector {
      id: undoActOut
      waitForEnd: true
    }
    onExited: function(code) {
      var data = view.parse(undoActOut.text)
      if (data && data.ok) view.notice = data.message ? String(data.message) : "Done."
      else view.error = data && data.error ? String(data.error)
        : "That did not work (exit " + code + ")."
      view.refresh()
    }
  }

  Process {
    id: ignoreAct
    stdout: StdioCollector {
      id: ignoreActOut
      waitForEnd: true
    }
    onExited: {
      var data = view.parse(ignoreActOut.text)
      if (!data || !data.ok) view.error = "Could not change that."
      view.refresh()
    }
  }

  Process {
    id: histAct
    stdout: StdioCollector {
      id: histActOut
      waitForEnd: true
    }
    onExited: function(code) {
      var data = view.parse(histActOut.text)
      if (code === 0 && data && data.ok) {
        view.notice = "Log cleared."
      } else {
        view.error = data && data.error ? String(data.error)
          : "Could not clear the log (exit " + code + ")."
      }
      view.refresh()
    }
  }

  function parse(raw) {
    var text = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (text === "") return null
    // status prints exactly one line of JSON; the others do too, but take the
    // last line so a stray warning never breaks the parse.
    var lines = text.split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.charAt(0) !== "{") continue
      try {
        return JSON.parse(line)
      } catch (error) {
        continue
      }
    }
    return null
  }

  Timer {
    id: armTimer
    interval: 6000
    onTriggered: {
      view.armed = ""
      if (view.notice.indexOf("Press ") === 0) view.notice = ""
    }
  }

  // ------------------------------------------------------------------ view
  // The cap is on the whole view, not just the list: the run log can grow for
  // as long as the history is kept, and an item that grew past the card would
  // push the panel's own chrome off the bottom edge. The Flickable takes what
  // is left after the status strip and scrolls inside it.
  readonly property real listHeight: Math.max(Style.space(72),
    Math.max(Style.space(120), view.maxHeight) - statusText.height - Style.space(6))

  implicitHeight: listFlick.height + statusText.height + Style.space(6)
  height: implicitHeight

  Flickable {
    id: listFlick
    width: parent.width
    height: view.listHeight
    contentWidth: width
    contentHeight: layout.height
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    function ensureVisible(index) {
      var item = view.rowItems[index]
      if (!item) return
      var origin
      try {
        origin = item.mapToItem(contentItem, 0, 0)
      } catch (e) {
        // The row was destroyed since it registered; the next rebuild
        // repopulates the cache with fresh geometry.
        delete view.rowItems[index]
        return
      }
      var top = origin.y
      var bottom = top + item.height
      if (top < contentY) contentY = Math.max(0, top - Style.space(8))
      else if (bottom > contentY + height)
        contentY = Math.min(Math.max(0, bottom - height + Style.space(8)),
          Math.max(0, contentHeight - height))
    }

    Column {
      id: layout
      width: listFlick.width
      spacing: Style.space(12)

      // ---------------------------------------------------------- headline
      Item {
        id: head
        width: parent.width
        height: headCol.height

        Column {
          id: headCol
          width: parent.width
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: view.headline()
            color: view.runCount > 0 ? view.fg : view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: view.subline()
            visible: text !== ""
            color: view.faint
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // The cursor rows live in their own Column so ensureVisible can read
      // their geometry directly; sections below them are static.
      Item {
        width: parent.width
        height: cursorLayer.height

        Column {
          id: cursorLayer
          width: parent.width
          spacing: Style.space(4)

          // ===================== auto-clean switch =====================
          Rectangle {
            id: autoRow
            width: parent.width
            height: Math.max(autoCol.height, toggleButton.height) + Style.space(16)
            radius: Style.cornerRadius
            color: autoHot || autoRow.hasCursor ? Util.alpha(view.accent, 0.12)
              : view.fill
            border.width: Math.max(1, Style.space(1))
            border.color: autoRow.hasCursor ? Util.alpha(view.accent, 0.55) : view.stroke

            readonly property bool hasCursor: view.cursor === 0
            readonly property bool autoHot: autoArea.containsMouse
            readonly property color tone: view.enabled ? (view.stale ? view.warning : view.success)
              : view.faint

            Behavior on color { ColorAnimation { duration: 110 } }

            Component.onCompleted: view.registerRow(0, autoRow)

            Column {
              id: autoCol
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: toggleButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                text: "Automatic clean-up"
                color: view.fg
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                width: parent.width
                text: !view.available
                  ? (view.schedule.error ? String(view.schedule.error)
                    : "Needs a systemd user session.")
                  : view.stale
                    ? "The timer points at an older copy of the plugin. Turn it off and on again."
                    : view.enabled
                      ? "Runs " + view.cadence + " through the conservative set."
                        + (view.tidyStamp(view.schedule.next) !== ""
                          ? " Next " + view.tidyStamp(view.schedule.next) + "." : "")
                        + (view.tidyStamp(view.schedule.last) !== ""
                          ? " Last " + view.tidyStamp(view.schedule.last) + "." : "")
                      : "Off. The conservative set only — nothing you would miss."
                color: view.stale ? view.warning : view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Row {
                spacing: Style.space(4)
                visible: view.available

                Repeater {
                  model: ["daily", "weekly"]

                  delegate: Rectangle {
                    id: cadenceChip
                    required property string modelData
                    readonly property bool active: view.cadence === cadenceChip.modelData
                    implicitWidth: cadenceLabel.implicitWidth + Style.space(14)
                    implicitHeight: Style.space(17)
                    radius: Style.cornerRadius
                    color: cadenceChip.active ? view.accent : Util.alpha(view.fg, 0.06)
                    border.width: Math.max(1, Style.space(1))
                    border.color: cadenceChip.active ? "transparent" : view.stroke

                    Text {
                      id: cadenceLabel
                      anchors.centerIn: parent
                      text: cadenceChip.modelData
                      color: cadenceChip.active ? view.readableOn(view.accent) : view.dim
                      font.family: view.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      // Choosing a cadence turns the job on if it was off:
                      // picking "daily" and then being told it is still off is
                      // a pointless second step.
                      onClicked: {
                        view.setCadence(cadenceChip.modelData)
                        if (view.available && !view.enabled) view.toggleSchedule()
                      }
                    }
                  }
                }
              }
            }

            Button {
              id: toggleButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: view.enabled ? "Turn off" : "Turn on"
              accent: view.accent
              foreground: view.enabled ? view.danger : view.fg
              fontFamily: view.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              focusable: false
              enabled: view.available
              opacity: view.available ? 1.0 : 0.45
              onClicked: view.toggleSchedule()
            }

            MouseArea {
              id: autoArea
              anchors.fill: parent
              anchors.rightMargin: toggleButton.width + Style.space(14)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                view.cursor = 0
                view.toggleSchedule()
              }
            }
          }

          // ===================== restore points =========================
          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "RESTORE POINTS"
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 0.6
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: view.undo.length > 0 ? "put a removed app back" : ""
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            width: parent.width
            visible: view.undo.length === 0
            text: "Nothing to put back yet. Uninstalling an app keeps its config aside for a while."
            color: view.faint
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: view.undo

            delegate: Rectangle {
              id: undoRow
              required property var modelData
              required property int index

              readonly property int rowIndex: view.undoBase + undoRow.index
              readonly property bool hasCursor: view.cursor === undoRow.rowIndex
              readonly property bool hot: undoArea.containsMouse
              readonly property bool usable: modelData.available !== false

              width: cursorLayer.width
              height: Math.max(undoCol.height, restoreButton.height) + Style.space(12)
              radius: Style.cornerRadius
              color: undoRow.hasCursor ? Util.alpha(view.accent, 0.20)
                : undoRow.hot ? Util.alpha(view.fg, 0.07) : view.fill
              border.width: Math.max(1, Style.space(1))
              border.color: undoRow.hasCursor ? Util.alpha(view.accent, 0.55) : view.stroke

              Behavior on color { ColorAnimation { duration: 110 } }

              Component.onCompleted: view.registerRow(undoRow.rowIndex, undoRow)

              Column {
                id: undoCol
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: restoreButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: modelData.name || modelData.id || "an application"
                  color: undoRow.usable ? view.fg : view.faint
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: "Removed " + view.when(modelData.at)
                    + (undoRow.usable
                      ? " · backup " + Model.formatBytes(modelData.archiveBytes || 0)
                      : " · backup no longer on disk")
                  color: undoRow.usable ? view.dim : view.warning
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Button {
                id: restoreButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: undoRow.usable ? "Put it back" : "Unavailable"
                iconText: "\uf01e"
                accent: view.accent
                foreground: view.fg
                fontFamily: view.fontFamily
                fontSize: Style.font.caption
                bordered: true
                focusable: false
                enabled: undoRow.usable
                opacity: undoRow.usable ? 1.0 : 0.45
                onClicked: {
                  view.cursor = undoRow.rowIndex
                  view.restorePicked()
                }
              }

              MouseArea {
                id: undoArea
                anchors.fill: parent
                anchors.rightMargin: restoreButton.width + Style.space(12)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  view.cursor = undoRow.rowIndex
                  view.restorePicked()
                }
              }
            }
          }

          // ===================== ignored folders ========================
          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "IGNORED"
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 0.6
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: view.ignored.length > 0 ? "never measured, never cleaned" : ""
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            width: parent.width
            visible: view.ignored.length === 0
            text: "Nothing ignored. Use Space, then Ignore this folder, to protect a path."
            color: view.faint
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: view.ignored

            delegate: Rectangle {
              id: ignoreRow
              required property string modelData
              required property int index

              readonly property int rowIndex: view.ignoreBase + ignoreRow.index
              readonly property bool hasCursor: view.cursor === ignoreRow.rowIndex
              readonly property bool hot: ignoreArea.containsMouse

              width: cursorLayer.width
              height: Math.max(Style.space(24), ignoreLabel.implicitHeight + Style.space(8))
              radius: Style.cornerRadius
              color: ignoreRow.hasCursor ? Util.alpha(view.accent, 0.20)
                : ignoreRow.hot ? Util.alpha(view.fg, 0.07) : view.fill
              border.width: Math.max(1, Style.space(1))
              border.color: ignoreRow.hasCursor ? Util.alpha(view.accent, 0.55) : view.stroke

              Behavior on color { ColorAnimation { duration: 110 } }

              Component.onCompleted: view.registerRow(ignoreRow.rowIndex, ignoreRow)

              Text {
                id: ignoreLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: ignoreDrop.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: view.shortPath(ignoreRow.modelData)
                color: view.fg
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }

              Button {
                id: ignoreDrop
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                iconText: "\uf00d"
                tooltipText: "Let Tidy clean this again"
                accent: view.accent
                foreground: view.danger
                fontFamily: view.fontFamily
                fontSize: Style.font.caption
                focusable: false
                onClicked: {
                  view.cursor = ignoreRow.rowIndex
                  view.dropPicked()
                }
              }

              MouseArea {
                id: ignoreArea
                anchors.fill: parent
                anchors.rightMargin: ignoreDrop.width + Style.space(10)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  view.cursor = ignoreRow.rowIndex
                  view.dropPicked()
                }
              }
            }
          }
        }
      }

      // ============================ run log =============================
      Column {
        width: parent.width
        spacing: Style.space(4)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "RUN LOG"
            color: view.faint
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.6
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: view.runCount > view.runs.length
              ? "last " + view.runs.length + " of " + view.runCount
              : ""
            color: view.faint
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          width: parent.width
          visible: view.runs.length === 0
          text: "No runs recorded yet."
          color: view.faint
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: view.runs

          delegate: Item {
            id: runRow
            required property var modelData
            required property int index

            width: layout.width
            height: Style.space(22)

            Row {
              anchors.fill: parent
              spacing: Style.space(8)

              Text {
                width: Style.space(66)
                text: Model.formatBytes(runRow.modelData.bytes || 0)
                color: (runRow.modelData.bytes || 0) > 0 ? view.success : view.faint
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: runLabel
                anchors.verticalCenter: parent.verticalCenter
                text: view.modeLabel(runRow.modelData.mode)
                  + (runRow.modelData.files > 0
                    ? " · " + runRow.modelData.files + (runRow.modelData.files === 1 ? " file" : " files")
                    : "")
                  + (runRow.modelData.label ? " · " + runRow.modelData.label : "")
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: view.when(runRow.modelData.at)
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // The hint strip: error, notice and the standing key hints, in that order of
  // importance, and never more than one of them. It sits outside the Flickable
  // so it cannot be scrolled away.
  Text {
    id: statusText
    anchors.top: listFlick.bottom
    anchors.topMargin: Style.space(6)
    width: parent.width
    text: view.status
    color: view.statusColor
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  function readableOn(color) {
    var r = color.r
    var g = color.g
    var b = color.b
    var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return lum > 0.62 ? "#101315" : "#ffffff"
  }

  // The panel's own hint row lives on the Clean tab, so this view carries its
  // own one-liner.
  readonly property string status: view.error !== "" ? view.error
    : view.notice !== "" ? view.notice
    : view.armed !== "" ? "Press the same key again to confirm."
    : "Enter acts · d cadence · x remove · h clear log · r refresh"
  readonly property color statusColor: view.error !== "" ? view.danger
    : view.notice !== "" ? view.success : view.faint
}
