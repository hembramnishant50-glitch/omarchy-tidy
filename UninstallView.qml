import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Uninstall — the second half of Tidy.
//
// Listing is read straight from pacman's local database and flatpak, the
// preview comes from `tidy-uninstall preview`, and the removal itself is one
// `tidy-uninstall run` call so the whole job costs a single polkit prompt.
//
// The point of this view is the preview: a package's installed size is almost
// never the whole story, because the configuration, caches and state the app
// wrote into the home directory are what really pile up. Both are shown, and
// only paths that no installed package owns are ever offered for removal.
Item {
  id: view

  // ------------------------------------------------------------- injected
  property string pluginDir: ""
  property color fg: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  property color dim: Util.alpha(Commons.Color.popups.text, 0.62)
  property color faint: Util.alpha(Commons.Color.popups.text, 0.38)
  property color danger: "#ef5f5f"
  property color success: "#3ecf72"
  property color warning: "#f0a83c"
  property string fontFamily: Style.font.family
  // Ceiling for the whole view, handed down by the panel. The list below takes
  // whatever is left after the search bar, the chips, the detail card and the
  // footer, so the Uninstall button always lands on the card instead of below
  // its bottom edge.
  property real maxHeight: Style.space(420)
  // Panel.qml's key catcher, so the search field can hand the keyboard back.
  property Item keyTarget: null

  signal requestClose()

  // ---------------------------------------------------------------- state
  property var apps: []
  property string query: ""
  // all | user | omarchy | system | flatpak | aur
  //
  // Defaults to what the person using this installed themselves. Omarchy's own
  // packages are what the desktop runs on; listing them next to real candidates
  // just buries the apps someone actually came here to remove.
  property string categoryFilter: "user"
  property int cursor: 0
  property var detail: null
  // idle | confirm | running | scan | wiping | done
  property string phase: "idle"
  // The confirm dialog only accepts an Agree once it has been on screen for a
  // moment. Without this, a double click on the button that opened it lands on
  // the Agree button underneath and removes the app before anyone read it.
  property bool confirmArmed: false
  property bool loading: true
  property bool previewing: false
  // Which app the in-flight preview is about. The cursor's detail card and the
  // confirmation dialog can be interested in two different apps at the same
  // time — that is exactly what ticking a row without moving the cursor does —
  // so a bare boolean cannot say whose numbers are still coming.
  property string previewId: ""
  // Every preview seen this session, keyed by app id. Moving the cursor back to
  // a row should not cost another second, and the confirmation has to be able to
  // talk about the app that is actually ticked rather than the one under the
  // cursor.
  property var previewCache: ({})
  // The next row that asked to be measured while the pipe was busy.
  property string previewQueued: ""
  property string listError: ""
  property bool runOk: false
  property string runMessage: ""
  property real freedBytes: 0
  property bool started: false
  // A package database entry is only half of what an app leaves on disk. The
  // rest is guessed from the app's own name, so the scan is its own phase with
  // its own answer, and the id/name are captured before the removal empties the
  // list underneath us.
  property string lastId: ""
  property string lastName: ""
  // Which step produced the current `done` screen, so the summary says what
  // actually happened rather than assuming the uninstall was the last thing.
  property string lastStage: "uninstall"
  // Set once a removal succeeds, and the trigger for re-reading the app list on
  // the way out of the overlay.
  property bool removedSomething: false
  property var scanItems: []
  property var scanChecked: ({})
  property bool scanBusy: false
  property string scanError: ""
  property int scanCursor: 0
  property var wipePending: []
  // Same reasoning as the uninstall gate: the button that erases things is
  // armed a beat after the list appears, never merely on arrival.
  property bool wipeArmed: false

  // Batch selection, keyed by id rather than by row so it survives a re-filter
  // or a re-sort. Empty means single-app mode, and the tick column stays hidden
  // so a list nobody is multi-selecting looks exactly as it always did.
  property var picked: ({})
  // The ids the last successful removal reported, so the done screen can look
  // up the restore point that belongs to them.
  property var runOkIds: []
  // The restore point offered by the done screen. Only ever set when exactly one
  // app was removed: a batch would mean one password prompt per package to put
  // them all back, and the History tab lists them all anyway.
  property var undoPoint: null
  // Restoring has its own state rather than borrowing `runMessage`: that string
  // is what the done screen decides "moved to the Trash" from, and rewording it
  // to "Putting it back…" would change the heading mid-restore.
  property string undoState: ""   // "" | "busy" | "ok" | "err"
  property string undoMessage: ""

  readonly property bool overlayOpen: view.phase !== "idle"
  readonly property bool busy: view.loading || view.previewing
    || view.phase === "running" || view.phase === "wiping"

  readonly property int scanCount: view.scanItems ? view.scanItems.length : 0
  readonly property int scanChosen: {
    var n = 0
    for (var i = 0; i < view.scanItems.length; i++) if (view.scanChecked[i]) n++
    return n
  }
  readonly property real scanChosenBytes: {
    var b = 0
    for (var i = 0; i < view.scanItems.length; i++)
      if (view.scanChecked[i]) b += (view.scanItems[i].bytes || 0)
    return b
  }
  // What the app's own manifest made it look like its leftovers were worth.
  readonly property real scanFoundBytes: {
    var b = 0
    for (var i = 0; i < view.scanItems.length; i++) b += (view.scanItems[i].bytes || 0)
    return b
  }

  readonly property var filtered: {
    var q = view.query.trim().toLowerCase()
    var f = view.categoryFilter
    var out = []
    for (var i = 0; i < view.apps.length; i++) {
      var app = view.apps[i]
      if (f !== "all") {
        var matches
        if (f === "flatpak" || f === "aur") matches = app.source === f
        else matches = (app.category || "user") === f
        if (!matches) continue
      }
      if (q !== "") {
        var hay = (app.name + " " + (app.id || "") + " " + (app.desc || "") + " "
          + (app.remote || "") + " " + (app.source || "") + " "
          + (app.category || "")).toLowerCase()
        if (hay.indexOf(q) === -1) continue
      }
      out.push(app)
    }
    // Apps you installed first: those are the ones someone comes here to remove.
    // Anything not in the map is treated as Omarchy-shipped rather than user,
    // so an unrecognised category can never be presented as safe to remove.
    var rank = { user: 0, omarchy: 1 }
    out.sort(function(a, b) {
      var ra = rank[a.category], rb = rank[b.category]
      if (ra === undefined) ra = 1
      if (rb === undefined) rb = 1
      if (ra !== rb) return ra - rb
      var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
      if (na < nb) return -1
      if (na > nb) return 1
      return 0
    })
    return out
  }

  function countOf(kind) {
    var n = 0
    for (var i = 0; i < view.apps.length; i++) {
      var app = view.apps[i]
      if (kind === "all") n++
      else if (kind === "flatpak" || kind === "aur") { if (app.source === kind) n++ }
      else if ((app.category || "user") === kind) n++
    }
    return n
  }

  // ------------------------------------------------------------- selection
  function appById(id) {
    for (var i = 0; i < view.apps.length; i++)
      if (view.apps[i].id === id) return view.apps[i]
    return null
  }

  // Rebuilt rather than mutated: QML only re-evaluates a binding that reads
  // `picked` when the property itself is reassigned.
  function togglePick(id) {
    if (id === "") return
    var next = {}
    for (var k in view.picked) next[k] = view.picked[k]
    if (next[id]) delete next[id]
    else next[id] = true
    view.picked = next
  }

  function toggleCurrentPick() {
    if (view.current) view.togglePick(view.current.id)
  }

  function clearPicks() {
    if (view.pickedCount === 0) return
    view.picked = ({})
  }

  readonly property var pickedIds: {
    var out = []
    for (var id in view.picked) if (view.picked[id]) out.push(id)
    // Sorted so the confirm text and the command line do not reshuffle between
    // two identical selections.
    out.sort()
    return out
  }

  readonly property int pickedCount: view.pickedIds.length

  readonly property real pickedBytes: {
    var b = 0
    for (var i = 0; i < view.pickedIds.length; i++) {
      var a = view.appById(view.pickedIds[i])
      if (a) b += (a.size || 0)
    }
    return b
  }

  readonly property bool selecting: view.pickedCount > 0

  // What the confirmation lists. For one app it is its leftovers; for a batch
  // it is the apps themselves, because a single app's leftovers are only known
  // after that app's package is gone.
  readonly property var confirmItems: {
    if (view.runMany) {
      var ids = view.runIds()
      var apps = []
      for (var i = 0; i < ids.length; i++) {
        var a = view.appById(ids[i])
        apps.push({
          key: ids[i],
          label: a ? a.name : ids[i],
          bytes: a ? (a.size || 0) : 0,
          warn: a ? view.isCritical(a.name) : false,
          isPath: false
        })
      }
      return apps
    }
    if (!view.runDetail || !view.runDetail.leftovers) return []
    var out = []
    for (var j = 0; j < view.runDetail.leftovers.length; j++) {
      var l = view.runDetail.leftovers[j]
      out.push({
        key: l.path,
        label: l.path,
        bytes: l.bytes || 0,
        warn: l.scope === "system",
        isPath: true
      })
    }
    return out
  }

  // What Enter, the footer button and the confirm dialog are all about: the
  // ticked set when there is one, otherwise the row under the cursor.
  function runIds() {
    if (view.pickedCount > 0) return view.pickedIds
    if (view.currentId === "") return []
    return [view.currentId]
  }

  readonly property bool runPicked: view.pickedCount > 0
  readonly property int runCount: view.pickedCount > 0 ? view.pickedCount : (view.currentId === "" ? 0 : 1)

  // Is anything in the target set on screen right now? Read from the list, which
  // is a few seconds old by the time the dialog opens, so it decides the
  // wording and the override rather than the outcome: `run` checks again.
  readonly property bool runRunning: {
    var ids = view.runIds()
    for (var i = 0; i < ids.length; i++) {
      var a = view.appById(ids[i])
      if (a && a.running) return true
    }
    return false
  }

  // ------------------------------------------------------- the run set
  //
  // Everything the confirmation dialog says is about the set that is about to
  // go, which is not the cursor row the moment a single row is ticked. Naming
  // or sizing the app under the cursor while deleting a different one is the
  // exact mistake this dialog exists to prevent, so the dialog reads from here
  // and never from `view.detail`/`view.current` directly.
  readonly property bool runMany: view.runCount > 1
  readonly property var runApp: view.runCount === 1 ? view.appById(view.runIds()[0]) : null
  // The one preview this dialog needs. A batch never has one: its leftovers are
  // only known once each package is gone.
  readonly property var runDetail: {
    if (view.runCount !== 1) return null
    var id = view.runIds()[0]
    if (view.detail && view.detail.id === id) return view.detail
    return view.previewCache[id] || null
  }
  // True only while the dialog is waiting for the number it is about to show.
  // A batch is never blocked by a measurement, and neither is a single app whose
  // size is already known — which is what used to make a batch's Agree button
  // sit dead while an unrelated row was being measured.
  readonly property bool runMeasuring: view.runCount === 1 && view.runDetail === null
    && view.previewing && view.previewId === view.runIds()[0]
  readonly property real runBytes: view.runDetail
    ? (view.runDetail.packageBytes || 0) + (view.runDetail.leftoverBytes || 0)
    : (view.runApp ? (view.runApp.size || 0) : 0)
  readonly property string runName: view.runMany
    ? view.runCount + " apps"
    : (view.runApp ? view.runApp.name : (view.runIds()[0] || ""))
  readonly property int runLeftoverCount: view.runDetail && view.runDetail.leftovers
    ? view.runDetail.leftovers.length : 0
  readonly property int runLeftoverNear: view.runDetail ? (view.runDetail.leftoverNear || 0) : 0
  readonly property string runRequiredBy: view.runDetail ? (view.runDetail.requiredBy || "") : ""

  // The strongest warning any member of the set earns. A batch that contains one
  // boot-critical package has to say so, and a bootloader outranks the milder
  // "part of Omarchy" wording even when the batch also contains those.
  readonly property string runWarning: {
    var ids = view.runIds()
    var weak = ""
    for (var i = 0; i < ids.length; i++) {
      var w = view.dangerOf(view.appById(ids[i]))
      if (w === "") continue
      if (w.indexOf("Boot") === 0) return w
      if (weak === "") weak = w
    }
    return weak
  }

  // The chips that are actually on screen, in order, so Left/Right can walk
  // the same list the mouse sees.
  readonly property var filterOrder: {
    var out = ["all"]
    if (view.countOf("user") > 0) out.push("user")
    if (view.countOf("omarchy") > 0) out.push("omarchy")
    if (view.countOf("flatpak") > 0) out.push("flatpak")
    if (view.countOf("aur") > 0) out.push("aur")
    return out
  }

  function cycleFilter(delta) {
    var order = view.filterOrder
    var i = order.indexOf(view.categoryFilter)
    if (i === -1) i = 0
    view.categoryFilter = order[(i + delta + order.length) % order.length]
  }

  // The list as it is actually drawn: a section heading followed by the apps
  // in it. The heading is always there — even when the filter leaves a single
  // provenance — because "Ships with Omarchy" is exactly the row where the
  // label matters most, and a list of Omarchy defaults with no heading reads
  // like a list of the user's own apps.
  readonly property var rows: {
    var apps = view.filtered
    var counts = {}
    for (var i = 0; i < apps.length; i++) {
      var cat = apps[i].category || "user"
      counts[cat] = (counts[cat] || 0) + 1
    }
    var out = []
    var last = ""
    for (var j = 0; j < apps.length; j++) {
      var c = apps[j].category || "user"
      if (c !== last) {
        out.push({
          kind: "header", label: view.groupLabel(c), count: counts[c],
          category: c, key: "h:" + c
        })
        last = c
      }
      out.push({ kind: "app", index: j, app: apps[j], key: "a:" + (apps[j].id || apps[j].name) })
    }
    return out
  }

  // The heading's own mark, so a section is recognisable before it is read.
  function groupGlyph(cat) {
    if (cat === "omarchy") return "\uf2db"
    return "\uf007"
  }

  function groupLabel(cat) {
    if (cat === "omarchy") return "Ships with Omarchy"
    return "Installed by you"
  }

  // The real icon, when the app has one. `Icon=` is a theme name most of the
  // time, an absolute path occasionally, and a bare file name the rest of the
  // time; the row falls back to its provenance glyph when none of the three
  // resolves, so an iconless package is never a blank slot.
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property var iconDirs: [
    "/usr/share/pixmaps",
    "/usr/share/icons/hicolor/64x64/apps",
    "/usr/share/icons/hicolor/48x48/apps",
    "/usr/share/icons/hicolor/128x128/apps",
    "/usr/share/icons/hicolor/256x256/apps"
  ]

  function iconSource(app) {
    if (!app || !app.icon) return ""
    var name = String(app.icon)
    // An absolute `Icon=` is what the desktop file meant; if the file is gone
    // the Image simply fails and the glyph shows.
    if (name.charAt(0) === "/") return name
    // The theme, which is where the great majority of these resolve.
    var path = Quickshell.iconPath(name, true)
    if (path !== "") return path
    // `Icon=` sometimes names a file outright, extension and all.
    var candidates = [name + ".png", name + ".svg"]
    // Flatpak exports its icons outside the theme, under the app's own id.
    if (app.source === "flatpak") {
      var sizes = ["128x128", "64x64", "96x96", "48x48", "32x32"]
      var base = view.homeDir + "/.local/share/flatpak/exports/share/icons/hicolor"
      for (var s = 0; s < sizes.length; s++)
        candidates.push(base + "/" + sizes[s] + "/apps/" + name + ".png")
    }
    for (var d = 0; d < view.iconDirs.length; d++)
      candidates.push(view.iconDirs[d] + "/" + name)
    for (var i = 0; i < candidates.length; i++) {
      var p = Quickshell.iconPath(candidates[i], true)
      if (p !== "") return p
    }
    return ""
  }

  // atime is a floor, not a stopwatch: `relatime` only rewrites it once it is a
  // day or more stale, so this rounds to the unit that is actually meaningful
  // and never pretends to more precision than the timestamp has.
  function lastUsedText(ts) {
    var at = Number(ts) || 0
    if (at <= 0) return ""
    var s = Math.floor(Date.now() / 1000) - at
    if (s < 0) s = 0
    if (s < 86400) return "today"
    var d = Math.floor(s / 86400)
    if (d < 7) return d + "d"
    if (d < 30) return Math.floor(d / 7) + "w"
    if (d < 365) return Math.floor(d / 30) + "mo"
    return Math.floor(d / 365) + "y"
  }

  // Where an app came from, in the words the person looking at it would use.
  function provenanceOf(app, detail) {
    if (!app) return ""
    if (app.source === "flatpak")
      return "Flatpak · " + (app.remote || "flathub")
        + (detail && detail.installation ? " · " + detail.installation : "")
    if (app.source === "aur") return "AUR package"
    if (app.category === "omarchy") return "Ships with Omarchy"
    return "Installed by you"
  }

  // The section says where a package came from; this says how much damage it
  // does. The two used to be the same axis, but folding the "Base system"
  // section into "Ships with Omarchy" would have quietly downgraded the
  // bootloader, the initramfs, the kernel, the microcode and glibc to the
  // milder "part of Omarchy" wording. So danger is keyed off the package name,
  // independent of which section the row happens to sit in.
  readonly property var bootCritical: /^(limine|grub|refind|syslinux|efibootmgr|os-prober)$/
  readonly property var coreSystem: /^(mkinitcpio|systemd|glibc|pacman|filesystem|base|sudo)$/

  function isCritical(name) {
    var n = name || ""
    return /^linux/.test(n) || /-ucode$/.test(n)
      || view.bootCritical.test(n) || view.coreSystem.test(n)
  }

  // One predicate for "how much damage does removing this do", shared by the
  // detail card, the confirmation and the batch warning above, so a batch cannot
  // word a package more mildly than its own detail card would.
  function dangerOf(app) {
    if (!app) return ""
    var name = app.name || ""
    if (/^linux/.test(name) || /-ucode$/.test(name)
      || view.bootCritical.test(name))
      return "Boot-critical — removing this can leave the machine unbootable."
    if (view.coreSystem.test(name))
      return "Core system package — removing this can leave the system unrepairable."
    if ((app.category || "user") === "omarchy")
      return "Part of Omarchy — removing it can break the desktop."
    return ""
  }

  readonly property string removalWarning: view.dangerOf(view.current)

  readonly property var current: view.filtered.length === 0
    ? null
    : view.filtered[Math.max(0, Math.min(view.cursor, view.filtered.length - 1))]
  readonly property string currentId: view.current ? view.current.id : ""
  // The card is only "measuring" when the measurement in flight is the one for
  // the row it is showing. A preview fetched for the confirmation must not put
  // a spinner on a row that is not being measured.
  readonly property bool cursorMeasuring: view.previewing && view.previewId === view.currentId

  readonly property real detailBytes: view.detail
    ? (view.detail.packageBytes || 0) + (view.detail.leftoverBytes || 0)
    : 0
  readonly property int leftoverCount: view.detail && view.detail.leftovers
    ? view.detail.leftovers.length
    : 0
  // Name-similar paths the scanner refused to call leftovers. Counted, never
  // offered unattended; the reviewed scan is where they get looked at.
  readonly property int leftoverNear: view.detail ? (view.detail.leftoverNear || 0) : 0
  readonly property string requiredBy: view.detail ? (view.detail.requiredBy || "") : ""
  // What the wipe report actually did, so the done screen does not claim to
  // have freed something it moved to the trash instead.
  readonly property bool trashed: view.runMessage.indexOf("Trash") !== -1
  // A wipe can do both — some of the paths are in $HOME and go to the trash,
  // the system ones are deleted — so "no removals at all" is the honest test
  // for calling the result a move rather than a free-up.
  readonly property bool trashedOnly: view.trashed
    && view.runMessage.indexOf("removed") === -1

  implicitHeight: layout.height
  height: layout.height

  // Only the list flexes. Everything above and below it is measured rather
  // than guessed, so the sum can never push the footer — and with it the
  // Uninstall button — past the bottom edge of the card.
  readonly property real chromeHeight: searchBar.height + chipStrip.height
    + detailCard.height + footerRow.height + layout.spacing * 4
  readonly property real listHeight: Math.max(Style.space(96),
    view.maxHeight - view.chromeHeight)

  // -------------------------------------------------------------- lifecycle
  function start() {
    if (view.started) return
    view.started = true
    view.loading = true
    view.listError = ""
    listProc.running = true
  }

  function reload() {
    view.apps = []
    view.detail = null
    view.query = ""
    view.cursor = 0
    view.loading = true
    view.previewing = false
    // The cache is keyed by app id and the list is about to be re-read: anything
    // it held was measured against the package database as it was before this
    // run, so it is exactly the kind of confidence that has to be thrown away.
    view.previewId = ""
    view.previewCache = ({})
    view.previewQueued = ""
    view.listError = ""
    view.started = true
    view.phase = "idle"
    view.picked = ({})
    view.undoPoint = null
    view.runOkIds = []
    view.undoState = ""
    view.undoMessage = ""
    listProc.running = true
  }

  function focusSearch() {
    searchField.forceActiveFocus()
  }

  function focusList() {
    if (view.keyTarget) view.keyTarget.forceActiveFocus()
  }

  function moveCursor(delta) {
    if (view.filtered.length === 0) return
    view.cursor = Math.max(0, Math.min(view.filtered.length - 1, view.cursor + delta))
    listFlick.ensureVisible(view.cursor)
  }

  // `id` defaults to the row under the cursor; the confirmation passes the app
  // it is actually about when that is not the same thing.
  function requestPreview(id) {
    var target = (id === undefined || id === "") ? view.currentId : id
    if (target === "") return
    var cached = view.previewCache[target]
    if (cached) {
      if (target === view.currentId) view.detail = cached
      return
    }
    // One measurement at a time. A request that arrives while the pipe is busy
    // waits its turn rather than being dropped, so arrowing through the list
    // cannot leave the card of the row you stopped on permanently blank.
    if (previewProc.running) {
      view.previewQueued = target
      return
    }
    view.previewing = true
    view.previewId = target
    if (target === view.currentId) view.detail = null
    previewProc.command = ["/usr/bin/bash", view.pluginDir + "/scripts/tidy-uninstall",
      "preview", target]
    previewProc.running = true
  }

  // The gate. Every path that removes something — the footer button, Enter on a
  // row, the row's own action — ends up here, and the only way forward from
  // here is an explicit Agree in the dialog below.
  function askUninstall() {
    var ids = view.runIds()
    if (ids.length === 0 || view.phase === "running") return
    // Measure if we have not already. The dialog opens either way, so the click
    // always produces a visible answer, and the numbers fill in under it. A
    // batch is left unmeasured on purpose: a preview is a second per package,
    // and the dialog has the installed sizes already.
    if (ids.length === 1 && !view.runDetail) view.requestPreview(ids[0])
    view.confirmArmed = false
    view.phase = "confirm"
    armTimer.restart()
  }

  function confirmUninstall() {
    // Three independent guards, so no stray key, click or timer can skip the
    // dialog: it must still be the active surface, it must have been armed, and
    // nothing may still be measuring.
    if (view.phase !== "confirm") return
    if (!view.confirmArmed || view.runMeasuring) return
    var ids = view.runIds()
    if (ids.length === 0) return
    // Remember what is going away: `run` reloads nothing, but the scan that
    // follows needs the name after the row is gone from the list.
    view.lastId = ids[0]
    // The picked app, which is not necessarily the one under the cursor: with a
    // selection the detail card may be showing something that is staying put.
    var first = view.appById(ids[0])
    view.lastName = ids.length === 1
      ? ((first ? first.name : "") || (view.detail && view.detail.name) || ids[0])
      : ids.length + " apps"
    view.lastStage = "uninstall"
    view.removedSomething = false
    view.phase = "running"
    view.runOk = false
    view.runMessage = ""
    view.freedBytes = 0
    view.runOkIds = []
    view.undoPoint = null
    view.undoState = ""
    view.undoMessage = ""
    var command = ["/usr/bin/bash", view.pluginDir + "/scripts/tidy-uninstall", "run"]
    command = command.concat(ids)
    // Only when the list said something in the set is on screen: this is the
    // deliberate override of the running-process refusal, and the button says
    // "anyway" because of it.
    if (view.runRunning) command.push("--force")
    runProc.command = command
    runProc.running = true
  }

  // Put back the app the done screen is offering. Reinstalls the package first
  // and unpacks the archived configuration on top of it, which is why it takes
  // a password prompt and is never automatic.
  function restoreUndo() {
    if (view.undoPoint === null || view.undoState === "busy") return
    view.undoState = "busy"
    view.undoMessage = ""
    undoProc.command = ["/usr/bin/python3", view.pluginDir + "/scripts/tidy-state",
      "undo-restore", String(view.undoPoint.at)]
    undoProc.running = true
  }

  function dismiss() {
    view.confirmArmed = false
    view.wipeArmed = false
    view.phase = "idle"
    // The list came from pacman's database before anything was removed, so the
    // app that just went is still sitting in it. Re-read only when something
    // actually changed, so a plain cancel stays instant.
    if (view.removedSomething) {
      view.removedSomething = false
      view.reload()
    }
  }

  // -------------------------------------------------------- leftover scan
  //
  // Removal takes the package's own files; this finds the configuration,
  // caches and state the app wrote into $HOME afterwards. Nothing here is
  // assumed: the paths come from the scanner, which drops anything an installed
  // package still owns, and every one of them is checked by `wipe` again before
  // the filesystem is touched.
  function startScan() {
    if (view.lastId === "") return
    view.scanBusy = true
    view.scanError = ""
    view.scanItems = []
    view.scanChecked = ({})
    view.wipePending = []
    view.wipeArmed = false
    view.phase = "scan"
    scanProc.command = ["/usr/bin/bash", view.pluginDir + "/scripts/tidy-uninstall",
      "scan", view.lastId, view.lastName]
    scanProc.running = true
  }

  // ------------------------------------------------ put it back (restore)
  // The uninstaller archives the $HOME half of an app before it removes it,
  // under a size cap, and `tidy-state undo-list` is where those archives are
  // listed. Only offered when a single app was removed: undoing a batch would
  // mean one password prompt per package, and the History tab has them all.
  function loadUndoPoint() {
    if (view.runOkIds.length !== 1) {
      view.undoPoint = null
      return
    }
    undoListProc.command = ["/usr/bin/python3", view.pluginDir + "/scripts/tidy-state",
      "undo-list"]
    undoListProc.running = true
  }

  function toggleScanItem(i) {
    // Rebuilt rather than mutated: QML only re-evaluates bindings that depend
    // on `scanChecked` when the property itself is reassigned.
    var next = {}
    for (var k = 0; k < view.scanItems.length; k++) next[k] = view.scanChecked[k]
    next[i] = !next[i]
    view.scanChecked = next
  }

  function setAllScan(value) {
    var next = {}
    for (var i = 0; i < view.scanItems.length; i++) next[i] = value
    view.scanChecked = next
  }

  function moveScanCursor(delta) {
    if (view.scanItems.length === 0) { view.scanCursor = 0; return }
    view.scanCursor = Math.max(0, Math.min(view.scanItems.length - 1,
      view.scanCursor + delta))
    scanFlick.ensureVisible(view.scanCursor)
  }

  function keepLeftovers() {
    view.scanItems = []
    view.scanChecked = ({})
    view.dismiss()
  }

  function chosenPaths() {
    var out = []
    for (var i = 0; i < view.scanItems.length; i++)
      if (view.scanChecked[i]) out.push(view.scanItems[i].path)
    return out
  }

  function wipeLeftovers() {
    if (view.phase !== "scan" || !view.wipeArmed || view.scanBusy) return
    var paths = view.chosenPaths()
    if (paths.length === 0) return
    view.wipePending = paths
    view.wipeArmed = false
    view.lastStage = "wipe"
    view.phase = "wiping"
    wipeProc.command = ["/usr/bin/bash", view.pluginDir + "/scripts/tidy-uninstall",
      "wipe"].concat(paths)
    wipeProc.running = true
  }

  function handleKey(event) {
    if (view.phase === "confirm") {
      if (event.key === Qt.Key_Escape || event.text === "n" || event.text === "N") {
        view.dismiss()
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.text === "y" || event.text === "Y") {
        view.confirmUninstall()
        event.accepted = true
      }
      return
    }
    if (view.phase === "done") {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        view.dismiss()
        event.accepted = true
        return
      }
      if (event.text === "r" || event.text === "R") {
        view.dismiss()
        view.reload()
        event.accepted = true
      }
      return
    }
    if (view.phase === "running" || view.phase === "wiping") {
      event.accepted = true
      return
    }
    if (view.phase === "scan") {
      if (view.scanBusy) {
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Escape) {
        view.keepLeftovers()
        event.accepted = true
        return
      }
      if (event.text === "a" || event.text === "A") {
        view.setAllScan(true)
        event.accepted = true
        return
      }
      if (event.text === "n" || event.text === "N") {
        view.setAllScan(false)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Down || event.text === "j") {
        view.moveScanCursor(1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Up || event.text === "k") {
        view.moveScanCursor(-1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Space) {
        view.toggleScanItem(view.scanCursor)
        event.accepted = true
        return
      }
      // Only the armed button, or this, because nothing else in this phase
      // destroys anything: the scan itself is read-only.
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        view.wipeLeftovers()
        event.accepted = true
      }
      return
    }

    if (event.key === Qt.Key_Escape) {
      // A selection is the newest thing on screen, so it is the first thing
      // Escape drops: closing the panel out from under a half-made batch is a
      // worse answer than clearing it.
      if (view.pickedCount > 0) {
        view.clearPicks()
        event.accepted = true
        return
      }
      if (view.query !== "") {
        view.query = ""
        searchField.text = ""
        event.accepted = true
        return
      }
      view.requestClose()
      event.accepted = true
      return
    }
    if (searchField.activeFocus) {
      // Editing the query: text belongs to the field, only step out on the
      // keys the field cannot use.
      if (event.key === Qt.Key_Down) {
        view.focusList()
        view.moveCursor(1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Up) {
        view.focusList()
        view.moveCursor(-1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        view.askUninstall()
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
    if (event.key === Qt.Key_Space) {
      // Space is the pick key in the cleaner's list too, so it means the same
      // thing here as clicking the tick does.
      view.toggleCurrentPick()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Left) {
      view.cycleFilter(-1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Right) {
      view.cycleFilter(1)
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Slash || event.text === "/") {
      view.focusSearch()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      view.askUninstall()
      event.accepted = true
      return
    }
    if (event.text !== "" && event.text.charCodeAt(0) >= 32) {
      // Typing anywhere in the list starts a search rather than doing nothing.
      view.query = event.text
      searchField.text = event.text
      searchField.cursorPosition = searchField.text.length
      view.focusSearch()
      event.accepted = true
    }
  }

  // The card follows the cursor. A cached figure appears at once; otherwise the
  // row is measured after a beat, so holding an arrow key down does not fire a
  // measurement per row passed over.
  function syncDetail() {
    var id = view.currentId
    if (id === "") {
      view.detail = null
      return
    }
    view.detail = view.previewCache[id] || null
    if (view.detail === null) previewTimer.restart()
  }

  onCategoryFilterChanged: {
    view.cursor = 0
    listFlick.contentY = 0
    view.syncDetail()
  }

  onCurrentIdChanged: view.syncDetail()

  Timer {
    id: previewTimer
    interval: 180
    repeat: false
    onTriggered: view.requestPreview()
  }

  // A dialog that opens under the pointer is a dialog that a double click
  // dismisses before it was ever read. Waiting a beat before the Agree button
  // accepts a click makes agreeing deliberate instead of incidental.
  Timer {
    id: armTimer
    interval: 400
    repeat: false
    onTriggered: view.confirmArmed = true
  }

  // The leftover list appears fully ticked, so the same beat of delay stands
  // between seeing it and being able to erase it.
  Timer {
    id: wipeArmTimer
    interval: 400
    repeat: false
    onTriggered: view.wipeArmed = true
  }

  // ------------------------------------------------------------------ data
  Process {
    id: listProc
    command: ["/usr/bin/bash", view.pluginDir + "/scripts/tidy-uninstall", "list"]
    stdout: StdioCollector {
      id: listOut
      waitForEnd: true
    }
    onExited: function(code) {
      view.loading = false
      if (code !== 0) {
        view.listError = "Could not read the installed application list"
        return
      }
      try {
        var data = JSON.parse(listOut.text)
        if (data && data.ok && data.apps) view.apps = data.apps
        else view.listError = "Could not read the installed application list"
      } catch (e) {
        view.listError = "Could not read the installed application list"
      }
    }
  }

  Process {
    id: previewProc
    stdout: StdioCollector {
      id: previewOut
      waitForEnd: true
    }
    onExited: function(code) {
      var measuredId = view.previewId
      view.previewing = false
      view.previewId = ""
      var got = false
      if (code === 0) {
        try {
          var data = JSON.parse(previewOut.text)
          if (data && data.ok && data.id) {
            got = true
            var next = {}
            for (var k in view.previewCache) next[k] = view.previewCache[k]
            next[data.id] = data
            view.previewCache = next
            // The card only takes it when the answer is about the row it is
            // showing; a measurement fetched for the confirmation must not
            // overwrite the cursor's card with another app's figure.
            if (data.id === view.currentId) view.detail = data
          }
        } catch (e) {
        }
      }
      // A failed measurement leaves the previous card up, which would show
      // numbers for an application that may not even answer anymore — a blank
      // card is a smaller lie than a stale one.
      if (!got && view.currentId === measuredId) view.detail = null
      // A row that was reached while some other row was being measured was held
      // back by the single measurement pipe. The pipe is free now, so take it.
      var queued = view.previewQueued
      view.previewQueued = ""
      if (queued !== "") view.requestPreview(queued)
    }
  }

  Process {
    id: runProc
    stdout: StdioCollector {
      id: runOut
      waitForEnd: true
    }
    onExited: function(code) {
      var text = String(runOut.text || "")
      var lines = text.split("\n")
      var matched = false
      var okIds = []
      var bytes = 0
      var msgs = []
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^RESULT\s+(\S+)\s+(ok|err|skip)\s+(\d+)\s+(\d+)\s*(.*)$/)
        if (!m) continue
        matched = true
        if (m[2] === "ok") {
          okIds.push(m[1])
          bytes += Number(m[3]) || 0
          if (m[5]) msgs.push(m[5])
        } else if (m[5]) {
          // A batch of five that refuses one has to say which one. The single-app
          // case reads the same as it always did because the prefix is the id it
          // just asked about.
          msgs.push(view.pickedCount > 1 ? m[1] + " — " + m[5] : m[5])
        }
      }
      view.runOkIds = okIds
      view.freedBytes = bytes
      view.runOk = okIds.length > 0
      if (!matched) {
        view.runOk = false
        view.runMessage = code === 0
          ? "Removal finished without a report"
          : "Removal failed"
      } else if (msgs.length === 0) {
        view.runMessage = view.runOk ? "Removed" : "Removal failed"
      } else {
        view.runMessage = msgs.join("  ·  ")
      }
      if (view.runOk) view.loadUndoPoint()
      // A successful removal is immediately followed by the question worth
      // asking next: what did it leave outside its own package files? Only for
      // a single app — a batch has no one name to search the whole tree for, and
      // each per-app scan costs about a second.
      if (view.runOk) view.removedSomething = true
      if (view.runOk && okIds.length === 1) {
        view.startScan()
      } else {
        view.phase = "done"
      }
    }
  }

  // The restore point that belongs to what was just removed. The uninstall
  // report does not carry it, so it is looked up by id afterwards, newest first.
  Process {
    id: undoListProc
    stdout: StdioCollector {
      id: undoListOut
      waitForEnd: true
    }
    onExited: function(code) {
      view.undoPoint = null
      if (code !== 0) return
      var data = null
      try {
        data = JSON.parse(String(undoListOut.text || ""))
      } catch (e) {
        return
      }
      if (!data || !data.ok || !data.entries) return
      for (var i = 0; i < data.entries.length; i++) {
        var e = data.entries[i]
        var ids = String(e.ids || e.id || "").split(",")
        for (var j = 0; j < ids.length; j++) {
          if (view.runOkIds.indexOf(ids[j]) !== -1) {
            view.undoPoint = e
            return
          }
        }
      }
    }
  }

  Process {
    id: undoProc
    stdout: StdioCollector {
      id: undoOut
      waitForEnd: true
    }
    onExited: function(code) {
      var data = null
      try {
        data = JSON.parse(String(undoOut.text || ""))
      } catch (e) {
        data = null
      }
      if (code === 0 && data && data.ok) {
        view.undoState = "ok"
        view.undoMessage = (view.undoPoint && view.undoPoint.name
          ? view.undoPoint.name + " is back"
          : "The application is back")
          + ". If it is still missing from your launcher, reinstall it from the terminal."
        view.undoPoint = null
        // The list is stale the moment something is put back into it, and the
        // app's own configuration is no longer awaiting a decision.
        view.removedSomething = false
        listProc.running = true
      } else {
        view.undoState = "err"
        view.undoMessage = (data && data.error)
          ? "Could not put it back: " + data.error
          : "Could not put it back. Nothing was changed."
      }
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function(code) {
      view.scanBusy = false
      var data = null
      if (code === 0) {
        try {
          data = JSON.parse(String(scanOut.text || ""))
        } catch (e) {
          data = null
        }
      }
      if (!data || !data.ok) {
        view.scanError = "Could not scan for leftovers"
      } else {
        var items = data.items || []
        view.scanItems = items
        // Only the name matches are ticked: a fuzzy hit is a guess, and a guess
        // should never be one keystroke away from being deleted.
        var checked = {}
        for (var i = 0; i < items.length; i++) checked[i] = items[i].match === "exact"
        view.scanChecked = checked
      }
      view.wipeArmed = false
      wipeArmTimer.restart()
    }
  }

  Process {
    id: wipeProc
    stdout: StdioCollector {
      id: wipeOut
      waitForEnd: true
    }
    onExited: function(code) {
      var text = String(wipeOut.text || "")
      var lines = text.split("\n")
      var matched = false
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^RESULT\s+(\S+)\s+(ok|err|skip)\s+(\d+)\s+(\d+)\s*(.*)$/)
        if (!m) continue
        matched = true
        view.runOk = m[2] === "ok"
        view.freedBytes = Number(m[3]) || 0
        view.runMessage = m[5] || (view.runOk ? "Removed" : "Could not remove the leftovers")
      }
      if (!matched) {
        view.runOk = false
        view.runMessage = code === 0
          ? "Cleanup finished without a report"
          : "Could not remove the leftovers"
      }
      if (view.runOk) view.removedSomething = true
      view.wipePending = []
      view.phase = "done"
    }
  }

  // ----------------------------------------------------------- components
  // Checkbox for the leftover rows. Paints only — the row's MouseArea owns the
  // toggle, so clicking the label is the same as clicking the box.
  component Tick: Item {
    id: tick
    property bool checked: false
    property bool dimmed: false
    property color tone: view.accent

    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? Style.space(4) : 0
      color: tick.checked ? tick.tone : "transparent"
      border.width: Math.max(1, Style.space(1))
      border.color: tick.checked ? tick.tone : Util.alpha(view.fg, 0.36)
      opacity: tick.dimmed ? 0.35 : 1.0

      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    Text {
      anchors.centerIn: parent
      visible: tick.checked
      text: "\uf00c"
      color: view.readableOn(tick.tone)
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
      opacity: tick.dimmed ? 0.5 : 1.0
    }
  }

  component FilledButton: Rectangle {
    id: action
    property string text: ""
    property string iconText: ""
    property bool disabled: false
    property bool destructive: false
    property color tone: view.accent
    signal clicked()

    readonly property color base: action.destructive ? view.danger : action.tone
    readonly property bool hot: actionArea.containsMouse && !action.disabled

    implicitWidth: label.implicitWidth + Style.space(30)
    implicitHeight: Style.space(32)
    radius: Style.cornerRadius
    color: action.disabled ? Util.alpha(view.fg, 0.07)
      : actionArea.pressed ? Qt.darker(action.base, 1.18)
      : action.hot ? Qt.lighter(action.base, 1.10)
      : action.base
    border.width: Math.max(1, Style.space(1))
    border.color: action.disabled ? Util.alpha(view.fg, 0.10) : "transparent"

    Behavior on color { ColorAnimation { duration: 110 } }

    Text {
      id: label
      anchors.centerIn: parent
      text: (action.iconText !== "" ? action.iconText + "  " : "") + action.text
      color: action.disabled ? view.faint : view.readableOn(action.base)
      font.family: view.fontFamily
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

  // A small filter pill: All / Yours / Omarchy / System / Flatpak.
  component SourceChip: Rectangle {
    id: chip
    property string label: ""
    property string value: "all"
    property int count: 0
    readonly property bool active: view.categoryFilter === chip.value
    readonly property bool hot: chipArea.containsMouse
    signal picked()

    implicitWidth: chipLabel.implicitWidth + Style.space(20)
    implicitHeight: Style.space(22)
    // Same corner as the panel's other buttons — a pill here read as a
    // different kind of control than the All/None pair in the Clean tab.
    radius: Style.cornerRadius
    color: chip.active ? view.accent
      : chip.hot ? Util.alpha(view.fg, 0.12)
      : Util.alpha(view.fg, 0.05)
    border.width: Math.max(1, Style.space(1))
    border.color: chip.active ? "transparent" : Util.alpha(view.fg, 0.10)

    Behavior on color { ColorAnimation { duration: 110 } }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label + " " + chip.count
      color: chip.active ? view.readableOn(view.accent) : view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: chipArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        view.categoryFilter = chip.value
        chip.picked()
      }
    }
  }

  function readableOn(color) {
    var r = color.r
    var g = color.g
    var b = color.b
    var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return lum > 0.62 ? "#101315" : "#ffffff"
  }

  // ------------------------------------------------------------------ view
  Column {
    id: layout
    width: parent.width
    spacing: Style.space(10)

    // ---------------------------------------------------------- search bar
    Item {
      id: searchBar
      width: parent.width
      height: Style.space(30)

      TextField {
        id: searchField
        anchors.fill: parent
        foreground: view.fg
        accent: view.accent
        font.family: view.fontFamily
        placeholderText: view.apps.length === 0 ? "Search installed apps"
          : "Search " + view.filtered.length + " of " + view.apps.length + " apps"
        verticalPadding: Style.space(2)
        onTextChanged: {
          if (view.query !== text) {
            view.query = text
            view.cursor = 0
          }
        }
        Keys.priority: Keys.BeforeItem
        Keys.onEscapePressed: function(event) {
          if (searchField.text !== "") {
            searchField.text = ""
          }
          view.focusList()
          event.accepted = true
        }
        Keys.onDownPressed: function(event) {
          view.focusList()
          view.moveCursor(1)
          event.accepted = true
        }
        Keys.onUpPressed: function(event) {
          view.focusList()
          view.moveCursor(-1)
          event.accepted = true
        }
        Keys.onReturnPressed: function(event) {
          view.askUninstall()
          event.accepted = true
        }
        Keys.onEnterPressed: function(event) {
          view.askUninstall()
          event.accepted = true
        }
      }
    }

    // -------------------------------------------------------- category row
    Flickable {
      id: chipStrip
      width: parent.width
      height: chipRow.implicitHeight
      contentWidth: chipRow.implicitWidth
      contentHeight: chipRow.implicitHeight
      clip: true
      interactive: chipRow.implicitWidth > chipStrip.width
      boundsBehavior: Flickable.StopAtBounds

      Row {
        id: chipRow
        spacing: Style.space(5)

        SourceChip { label: "All"; value: "all"; count: view.apps.length }
        SourceChip {
          label: "Yours"; value: "user"; count: view.countOf("user")
          visible: count > 0
        }
        SourceChip {
          label: "Omarchy"; value: "omarchy"; count: view.countOf("omarchy")
          visible: count > 0
        }
        SourceChip {
          label: "Flatpak"; value: "flatpak"; count: view.countOf("flatpak")
          visible: count > 0
        }
      }
    }

    // --------------------------------------------------------------- list
    Item {
      id: listBox
      width: parent.width
      height: view.listHeight

      Flickable {
        id: listFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: listCol.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        function ensureVisible(appIndex) {
          // Walk the drawn rows instead of multiplying by a fixed height:
          // a group heading makes the row at a given app index taller than
          // appIndex * rowHeight.
          var top = 0
          var rows = view.rows
          for (var i = 0; i < rows.length; i++) {
            var row = rows[i]
            var h = row.kind === "header" ? headerHeight : rowHeight
            if (row.kind === "app" && row.index === appIndex) {
              if (top < contentY) contentY = top
              else if (top + h > contentY + height) contentY = top + h - height
              return
            }
            top += h
          }
        }

        readonly property real rowHeight: Style.space(30)
        // Taller than the old caption so the section bar has room to look like
        // a bar. ensureVisible() below reads this, so the two stay in step.
        readonly property real headerHeight: Style.space(33)

        Column {
          id: listCol
          width: listFlick.width

          Repeater {
            model: view.rows

            delegate: Item {
              id: appRow
              required property var modelData
              required property int index

              readonly property bool isHeader: appRow.modelData.kind === "header"
              readonly property var app: appRow.isHeader ? null : appRow.modelData.app
              // The app's position within `filtered`, which is what the cursor
              // is expressed in — not the row's own index.
              readonly property int appIndex: appRow.isHeader ? -1 : appRow.modelData.index
              readonly property bool hasCursor: !appRow.isHeader && view.cursor === appRow.appIndex
              readonly property bool hot: !appRow.isHeader && rowArea.containsMouse
              readonly property string sourceGlyph: appRow.app === null ? ""
                : appRow.app.source === "flatpak" ? "\uf108"
                : appRow.app.source === "aur" ? "\uf085" : "\uf187"
              // Where it came from, right on the row: an Omarchy default is
              // the thing you most want to know before pressing uninstall.
              readonly property string badge: appRow.app === null ? ""
                : appRow.app.source === "flatpak" ? (appRow.app.remote || "flatpak")
                : appRow.app.source === "aur" ? "AUR"
                : appRow.app.category === "omarchy" ? "omarchy" : ""
              readonly property bool badgeWarns: appRow.app !== null
                && view.isCritical(appRow.app.name)
              // Multi-select, keyed off the same map the view keeps so a row
              // never has to be told twice.
              readonly property bool picked: appRow.app !== null
                && view.picked[appRow.app.id] === true
              // "" when there is no icon to draw, which is the signal for the
              // provenance glyph to take over rather than a blank slot.
              readonly property string iconSrc: view.iconSource(appRow.app)
              readonly property string lastText: appRow.app === null ? ""
                : view.lastUsedText(appRow.app.lastUsed)
              readonly property bool running: appRow.app !== null
                && appRow.app.running === true
              // The tick column is reserved on every row so nothing shifts when
              // selection starts; it is simply invisible until it means
              // something — something is picked, or this row is under the
              // pointer.
              readonly property bool tickVisible: !appRow.isHeader
                && (appRow.picked || view.selecting || appRow.hot)

              width: listCol.width
              height: appRow.isHeader ? listFlick.headerHeight : listFlick.rowHeight

              // ---- section bar ("Ships with Omarchy · 161") ----------------
              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Style.space(2)
                anchors.rightMargin: Style.space(2)
                anchors.topMargin: Style.space(7)
                anchors.bottomMargin: Style.space(4)
                visible: appRow.isHeader
                radius: Style.cornerRadius
                color: Util.alpha(view.fg, 0.06)

                Text {
                  id: headerGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(9)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: appRow.isHeader
                  text: appRow.isHeader ? view.groupGlyph(appRow.modelData.category) : ""
                  color: view.dim
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  id: headerLabel
                  anchors.left: headerGlyph.right
                  anchors.leftMargin: Style.space(7)
                  anchors.right: headerCount.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: appRow.isHeader
                  text: appRow.isHeader ? appRow.modelData.label.toUpperCase() : ""
                  color: view.dim
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 0.7
                  elide: Text.ElideRight
                }

                Text {
                  id: headerCount
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(9)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: appRow.isHeader
                  text: appRow.isHeader ? appRow.modelData.count : ""
                  color: view.faint
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: Style.space(2)
                anchors.rightMargin: Style.space(2)
                visible: !appRow.isHeader
                radius: Style.cornerRadius
                color: appRow.hasCursor ? Util.alpha(view.accent, 0.16)
                  : appRow.hot ? Util.alpha(view.fg, 0.06)
                  : "transparent"
                border.width: appRow.hasCursor ? Math.max(1, Style.space(1)) : 0
                border.color: Util.alpha(view.accent, 0.45)

                Behavior on color { ColorAnimation { duration: 110 } }
              }

              // ---- tick slot -----------------------------------------------
              // Anchored, not laid out, so the name column starts at the same x
              // whether or not the tick is showing.
              Item {
                id: tickSlot
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(16)
                height: Style.space(16)
                visible: !appRow.isHeader
                opacity: appRow.tickVisible ? 1 : 0

                Behavior on opacity { NumberAnimation { duration: 110 } }

                Tick {
                  anchors.fill: parent
                  checked: appRow.picked
                }
              }

              // ---- icon ----------------------------------------------------
              // The real icon from the desktop entry when there is one, the
              // provenance glyph when there is not. An app with no icon at all
              // is common — a library, a driver, a CLI tool — so the fallback
              // carries as much meaning as the icon does.
              Item {
                id: appGlyph
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                height: Style.space(18)
                visible: !appRow.isHeader

                Image {
                  id: appIcon
                  anchors.fill: parent
                  source: appRow.iconSrc
                  sourceSize.width: 48
                  sourceSize.height: 48
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  visible: appRow.iconSrc !== "" && status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  visible: !appIcon.visible
                  text: appRow.sourceGlyph
                  color: appRow.hasCursor ? view.fg : view.dim
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                id: appName
                anchors.left: appGlyph.right
                anchors.leftMargin: Style.space(7)
                anchors.right: appMeta.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                visible: !appRow.isHeader
                text: appRow.app === null ? "" : appRow.app.name
                color: view.fg
                font.family: view.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              // Provenance, how long ago it was last touched, and how much it
              // takes — right-aligned as one run so the name's elision edge is
              // the only thing that moves.
              Row {
                id: appMeta
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(7)
                visible: !appRow.isHeader

                Text {
                  id: appRunning
                  visible: appRow.running
                  text: "running"
                  color: view.warning
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  id: appBadge
                  visible: appRow.badge !== ""
                  text: appRow.badge
                  color: appRow.badgeWarns ? view.warning : view.faint
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: appLast
                  visible: appRow.lastText !== ""
                  text: appRow.lastText
                  color: view.faint
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: appSize
                  text: appRow.app === null ? "" : Model.formatBytes(appRow.app.size || 0)
                  color: view.faint
                  font.family: view.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              // The tick's hit area is folded into the row's rather than stacked
              // on top of it: the left gutter picks without moving the cursor,
              // and anywhere else on the row moves the cursor without picking.
              MouseArea {
                id: rowArea
                anchors.fill: parent
                enabled: !appRow.isHeader
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) {
                  if (appRow.tickVisible && mouse.x < Style.space(28)) {
                    view.togglePick(appRow.app.id)
                    return
                  }
                  view.cursor = appRow.appIndex
                  view.focusList()
                }
              }
            }
          }
        }

        ScrollKnob { flick: listFlick }
      }

      Text {
        anchors.centerIn: parent
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: view.loading || view.filtered.length === 0
        text: view.listError !== "" ? view.listError
          : view.loading ? "Reading installed applications…"
          : view.query !== "" ? "No app matches “" + view.query + "”"
          : "Nothing here"
        color: view.listError !== "" ? view.danger : view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // ------------------------------------------------------------- detail
    Rectangle {
      id: detailCard
      width: parent.width
      height: detailCol.implicitHeight + Style.space(18)
      radius: Style.cornerRadius
      color: Util.alpha(view.fg, 0.035)
      border.width: Math.max(1, Style.space(1))
      border.color: Util.alpha(view.fg, 0.08)

      Column {
        id: detailCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(9)
        spacing: Style.space(3)

        Item {
          width: parent.width
          height: Math.max(detailTitle.implicitHeight, detailTotal.implicitHeight)

          Text {
            id: detailTitle
            anchors.left: parent.left
            anchors.right: detailTotal.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: view.current
              ? view.current.name + (view.current.version ? "  " + view.current.version : "")
              : "No app selected"
            color: view.fg
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            id: detailTotal
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: view.detail !== null || view.cursorMeasuring
            text: view.detail === null
              ? "measuring…"
              : Model.formatBytes(view.detailBytes)
            color: view.detail === null ? view.faint : view.accent
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Text {
          width: parent.width
          text: {
            if (!view.current) return "Pick an application to see everything that would be removed."
            var bits = [view.provenanceOf(view.current, view.detail)]
            if (view.current.desc) bits.push(view.current.desc)
            return bits.join("  ·  ")
          }
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: view.removalWarning !== ""
          text: view.removalWarning
          color: view.warning
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: view.current !== null && view.current.running === true
          text: view.current
            ? view.current.name + " is still running — close it first, or the "
              + "removal will refuse to touch a live binary. The confirmation "
              + "has an “anyway”."
            : ""
          color: view.warning
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: {
            if (!view.current) return ""
            if (view.cursorMeasuring) return "Looking for leftovers…"
            if (!view.detail) return "Select again to measure."
            var bits = []
            bits.push(Model.formatBytes(view.detail.packageBytes || 0) + " installed")
            if (view.leftoverCount > 0)
              bits.push(view.leftoverCount + " leftover"
                + (view.leftoverCount === 1 ? "" : "s") + " · "
                + Model.formatBytes(view.detail.leftoverBytes || 0))
            else
              bits.push("no leftovers found")
            if (view.leftoverNear > 0)
              bits.push(view.leftoverNear + " similar path"
                + (view.leftoverNear === 1 ? "" : "s") + " left to review")
            if (view.detail.ownedFiles > 0) bits.push(view.detail.ownedFiles + " files")
            return bits.join("  ·  ")
          }
          color: view.faint
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: view.requiredBy !== ""
          text: "Required by " + view.requiredBy + " — remove those first."
          color: view.warning
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    // ------------------------------------------------------------- footer
    Item {
      id: footerRow
      width: parent.width
      height: Math.max(appsHint.implicitHeight, uninstallButton.height)

      Text {
        id: appsHint
        anchors.left: parent.left
        anchors.right: uninstallButton.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (view.phase === "scan") return "Space picks · a all · Enter removes the ticked paths"
          if (view.selecting)
            return view.pickedCount + " picked · Space adds or drops · Esc clears"
          return "↑↓ browse · ←→ filter · Space picks · / search · Enter confirms"
        }
        color: view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      FilledButton {
        id: uninstallButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        destructive: true
        iconText: "\uf1f8"
        // Not gated on `busy`: the corner measuring a row should not make the
        // button look broken. Pressing it opens the confirmation, which is what
        // decides whether anything actually happens.
        disabled: view.runCount === 0 || view.loading || view.phase === "running"
        text: {
          if (view.runCount === 0) return "Uninstall…"
          if (view.runPicked)
            return "Uninstall " + view.pickedCount + " ("
              + Model.formatBytes(view.pickedBytes) + ")…"
          if (view.detail && view.detailBytes > 0)
            return "Uninstall " + Model.formatBytes(view.detailBytes) + "…"
          return "Uninstall…"
        }
        onClicked: view.askUninstall()
      }
    }
  }

  // --------------------------------------------------------------- overlay
  Rectangle {
    id: overlayRect
    anchors.fill: parent
    visible: view.overlayOpen
    color: Commons.Color.popups.background

    MouseArea { anchors.fill: parent }

    // ---- confirm ---------------------------------------------------------
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(20)
      spacing: Style.space(8)
      visible: view.phase === "confirm"

      Text {
        width: parent.width
        text: view.runMany
          ? "\uf071  Remove " + view.runCount + " apps?"
          : "\uf071  Remove " + view.runName + "?"
        color: view.fg
        font.family: view.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: view.runMany
          ? "Nothing has been removed yet. Each app is removed with its own "
            + "package manager, and each one's leftovers are looked up separately "
            + "afterwards. Once you agree it cannot be undone."
          : "Nothing has been removed yet. The folders below are what this app "
            + "left behind, dependencies nothing else needs go as well, and once you "
            + "agree it cannot be undone."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        text: {
          if (view.runMany)
            return view.runCount + " apps · " + Model.formatBytes(view.pickedBytes)
              + " installed — leftovers are measured for each after the packages are gone"
          if (view.runMeasuring) return "Measuring what will be freed…"
          if (!view.runDetail)
            return Model.formatBytes(view.runBytes) + " installed — leftovers could "
              + "not be measured, so the total may grow"
          var s = Model.formatBytes(view.runBytes) + " will be freed — "
            + Model.formatBytes(view.runDetail.packageBytes || 0) + " installed"
          if (view.runLeftoverCount > 0)
            s += "  +  " + Model.formatBytes(view.runDetail.leftoverBytes || 0) + " in "
              + view.runLeftoverCount + " leftover folder"
              + (view.runLeftoverCount === 1 ? "" : "s")
          if (view.runLeftoverNear > 0)
            s += ", plus " + view.runLeftoverNear + " similar path"
              + (view.runLeftoverNear === 1 ? "" : "s") + " left alone"
          return s
        }
        color: view.fg
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.WordWrap
      }

      // The running-process guard, said out loud before the button is pressed
      // rather than discovered as a failure afterwards. The button below changes
      // its own label to match, which is the acknowledgement.
      Text {
        width: parent.width
        visible: view.runRunning
        text: {
          var who = view.runMany
            ? "Something in this set is still running"
            : (view.runApp ? view.runApp.name + " is still running" : "It is still running")
          return who + " — quit it first. Agreeing will remove it anyway, which can "
            + "leave the live copy writing into files that are about to be deleted."
        }
        color: view.warning
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        visible: view.runWarning !== ""
        text: view.runWarning
        color: view.warning
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        wrapMode: Text.WordWrap
      }

      Text {
        width: parent.width
        visible: !view.runMany
        text: view.provenanceOf(view.runApp, view.runDetail)
        color: view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: view.runRequiredBy !== "" && !view.runMany
        text: "Required by " + view.runRequiredBy + " — pacman will refuse until those are removed."
        color: view.warning
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Flickable {
        id: leftoversFlick
        width: parent.width
        // The dialog is centred in a card of a known height, so the list is what
        // gives way when the warning lines above it grow: the space reserved for
        // everything else is spent first, and the Agree button below can never be
        // pushed off the bottom edge.
        height: Math.max(Style.space(40),
          Math.min(leftoversCol.height, overlayRect.height - Style.space(310)))
        contentHeight: leftoversCol.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: leftoversCol
          width: parent.width
          spacing: Style.space(3)

          Repeater {
            // One list for both shapes: the leftovers of the one app, or the
            // apps themselves when a batch is going away.
            model: view.confirmItems

            delegate: Item {
              required property var modelData
              width: leftoversCol.width
              height: Style.space(20)

              Text {
                anchors.left: parent.left
                anchors.right: leftoverSize.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: modelData.warn ? view.warning : view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
                elide: modelData.isPath ? Text.ElideLeft : Text.ElideRight
              }

              Text {
                id: leftoverSize
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: Model.formatBytes(modelData.bytes)
                color: view.faint
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        ScrollKnob { flick: leftoversFlick }
      }

      Item {
        width: parent.width
        height: Math.max(cancelButton.height, confirmButton.height)

        Button {
          id: cancelButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Cancel"
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          bordered: true
          focusable: false
          onClicked: view.dismiss()
        }

        FilledButton {
          id: confirmButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          destructive: true
          iconText: "\uf1f8"
          text: {
            if (view.runMeasuring) return "Measuring…"
            if (view.runRunning)
              return view.runMany
                ? "Uninstall " + view.runCount + " anyway"
                : "Uninstall anyway"
            return view.runMany
              ? "Agree & uninstall " + view.runCount
              : "Agree & uninstall"
          }
          // Deliberately slow: armed a moment after the dialog opens, and never
          // while the size this dialog is about to show is still being measured.
          disabled: !view.confirmArmed || view.runMeasuring
          onClicked: view.confirmUninstall()
        }
      }
    }

    // ---- running ---------------------------------------------------------
    // Also used while the leftovers are being erased: same job, same bar, so
    // there is no second spinner to keep in step.
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(20)
      spacing: Style.space(10)
      visible: view.phase === "running" || view.phase === "wiping"

      Text {
        width: parent.width
        text: view.phase === "wiping" ? "Removing leftovers…" : "Uninstalling…"
        color: view.fg
        font.family: view.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        width: parent.width
        text: view.phase === "wiping"
          ? "Clearing " + view.wipePending.length + " leftover"
            + (view.wipePending.length === 1 ? "" : "s")
            + " of " + (view.lastName || view.currentId) + "."
          : "Removing " + (view.lastName || view.currentId)
            + (view.runCount > 1 ? " and everything they left behind."
              : " and everything it left behind.")
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Item {
        width: parent.width
        height: Style.space(6)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
          color: Util.alpha(view.fg, 0.10)
        }

        Rectangle {
          id: runBar
          width: parent.width * 0.35
          height: parent.height
          radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
          color: view.danger

          SequentialAnimation on x {
            loops: Animation.Infinite
            running: view.phase === "running" || view.phase === "wiping"
            NumberAnimation {
              from: 0
              to: runBar.parent.width - runBar.width
              duration: 900
              easing.type: Easing.InOutCubic
            }
            NumberAnimation {
              from: runBar.parent.width - runBar.width
              to: 0
              duration: 900
              easing.type: Easing.InOutCubic
            }
          }
        }
      }

      Text {
        width: parent.width
        text: view.phase === "wiping"
          ? "Only the paths named by the scan are touched, and they are checked "
            + "again inside the wipe."
          : "Approve the password prompt to remove system files."
        color: view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    // ---- leftover scan ---------------------------------------------------
    // The question the uninstaller never used to ask: the package is gone, but
    // the config, caches and state it wrote into $HOME are not touched by
    // pacman or flatpak. Everything here comes from `tidy-uninstall scan`,
    // which drops any path an installed package still owns; a name-only guess
    // arrives unticked and dimmed so it is never one keystroke from deletion.
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(20)
      spacing: Style.space(9)
      visible: view.phase === "scan"

      Text {
        width: parent.width
        text: "\uf002  " + (view.lastName || view.lastId) + " is gone"
        color: view.fg
        font.family: view.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: view.scanBusy
          ? "Looking through your configuration, caches and state…"
          : view.scanError !== ""
            ? view.scanError
            : view.scanCount === 0
              ? "Nothing was left behind outside the package. "
                + Model.formatBytes(view.freedBytes) + " freed."
              : "What it wrote outside its own package files is still here — "
                + view.scanCount + (view.scanCount === 1 ? " folder, " : " folders, ")
                + Model.formatBytes(view.scanFoundBytes) + " in total. Untick anything "
                + "you want to keep; only the ticked paths are removed."
        color: view.scanError !== "" ? view.danger : view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Item {
        width: parent.width
        height: Style.space(6)
        visible: view.scanBusy

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
          color: Util.alpha(view.fg, 0.10)
        }

        Rectangle {
          id: scanBar
          width: parent.width * 0.35
          height: parent.height
          radius: Style.cornerRadius > 0 ? Math.round(height / 2) : 0
          color: view.accent

          SequentialAnimation on x {
            loops: Animation.Infinite
            running: view.scanBusy
            NumberAnimation {
              from: 0
              to: scanBar.parent.width - scanBar.width
              duration: 900
              easing.type: Easing.InOutCubic
            }
            NumberAnimation {
              from: scanBar.parent.width - scanBar.width
              to: 0
              duration: 900
              easing.type: Easing.InOutCubic
            }
          }
        }
      }

      // All / None and the running total, so the size on the Delete button is
      // never a guess about what is about to go.
      Item {
        width: parent.width
        height: Math.max(scanAll.height, scanNone.height, scanTally.implicitHeight)
        visible: !view.scanBusy && view.scanError === "" && view.scanCount > 0

        Button {
          id: scanAll
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "All"
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          bordered: true
          focusable: false
          onClicked: view.setAllScan(true)
        }

        Button {
          id: scanNone
          anchors.left: scanAll.right
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: "None"
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          bordered: true
          focusable: false
          onClicked: view.setAllScan(false)
        }

        Text {
          id: scanTally
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: view.scanChosen + " of " + view.scanCount + " · "
            + Model.formatBytes(view.scanChosenBytes)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Flickable {
        id: scanFlick
        width: parent.width
        height: Math.min(scanCol.height, Style.space(196))
        contentHeight: scanCol.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: !view.scanBusy && view.scanError === "" && view.scanCount > 0

        function ensureVisible(i) {
          var rowH = Style.space(27)
          var top = i * rowH
          if (top < scanFlick.contentY) scanFlick.contentY = top
          else if (top + rowH > scanFlick.contentY + scanFlick.height)
            scanFlick.contentY = top + rowH - scanFlick.height
        }

        Column {
          id: scanCol
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: view.scanItems

            delegate: Item {
              id: scanRow
              required property var modelData
              required property int index

              width: scanCol.width
              height: Style.space(27)

              readonly property bool chosen: view.scanChecked[scanRow.index] === true
              readonly property bool cursorHere: view.scanCursor === scanRow.index
              readonly property bool isFuzzy: modelData.match !== "exact"

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: scanRowArea.containsMouse ? Util.alpha(view.fg, 0.05) : "transparent"
                border.width: scanRow.cursorHere ? Math.max(1, Style.space(1)) : 0
                border.color: Util.alpha(view.accent, 0.55)
              }

              Tick {
                id: scanTick
                anchors.left: parent.left
                anchors.leftMargin: Style.space(7)
                anchors.verticalCenter: parent.verticalCenter
                checked: scanRow.chosen
                dimmed: scanRow.isFuzzy
                tone: scanRow.isFuzzy ? view.warning : view.accent
              }

              Text {
                anchors.left: scanTick.right
                anchors.leftMargin: Style.space(9)
                anchors.right: scanRowSize.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.path
                color: scanRow.isFuzzy ? view.faint : view.fg
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }

              Text {
                id: scanRowSize
                anchors.right: parent.right
                anchors.rightMargin: Style.space(7)
                anchors.verticalCenter: parent.verticalCenter
                text: (scanRow.isFuzzy ? "guess · " : "")
                  + Model.formatBytes(modelData.bytes || 0)
                color: scanRow.isFuzzy ? view.faint : view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: scanRowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  view.scanCursor = scanRow.index
                  view.toggleScanItem(scanRow.index)
                }
              }
            }
          }
        }
      }

      Item {
        width: parent.width
        height: Math.max(keepButton.height, wipeButton.height, scanClose.height)
        visible: !view.scanBusy

        Button {
          id: keepButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: view.scanError === "" && view.scanCount > 0
          text: "Keep them"
          iconText: "\uf00c"
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          bordered: true
          focusable: false
          onClicked: view.keepLeftovers()
        }

        FilledButton {
          id: wipeButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: view.scanError === "" && view.scanCount > 0
          destructive: true
          iconText: "\uf1f8"
          text: view.scanChosen === 0
            ? "Delete nothing"
            : "Delete " + view.scanChosen + " ("
              + Model.formatBytes(view.scanChosenBytes) + ")"
          // Armed a beat after the list lands, and never while the scan is
          // still deciding what belongs in it.
          disabled: !view.wipeArmed || view.scanChosen === 0
          onClicked: view.wipeLeftovers()
        }

        FilledButton {
          id: scanClose
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: view.scanError !== "" || view.scanCount === 0
          iconText: "\uf00c"
          text: "Done"
          onClicked: view.dismiss()
        }
      }
    }

    // ---- done ------------------------------------------------------------
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(20)
      spacing: Style.space(10)
      visible: view.phase === "done"

      Text {
        width: parent.width
        text: {
          if (!view.runOk)
            return view.lastStage === "wipe"
              ? "Could not remove the leftovers" : "Could not uninstall"
          if (view.lastStage === "wipe")
            return view.trashedOnly
              ? "Moved to the Trash"
              : "Freed " + Model.formatBytes(view.freedBytes)
          if (view.runOkIds.length > 1)
            return "Removed " + view.runOkIds.length + " apps"
          return "Freed " + Model.formatBytes(view.freedBytes)
        }
        color: view.runOk ? view.success : view.danger
        font.family: view.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        width: parent.width
        text: {
          if (!view.runOk) return view.runMessage || "Nothing was removed."
          var who = view.lastName || view.currentId
          var lead
          if (view.lastStage === "wipe")
            lead = view.trashedOnly
              ? who + "’s leftovers are in the Trash, not deleted — empty it to "
                + "reclaim the space. "
              : who + "’s leftovers are gone. "
          else
            lead = view.runOkIds.length > 1
              ? who + " and everything they left behind are gone. "
              : who + " and everything it left behind are gone. "
          return lead + (view.runMessage || "")
        }
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      // Putting it back is the thing the uninstaller can do that a terminal
      // cannot do quickly, so it is offered where the regret happens instead of
      // being buried in the History tab.
      Text {
        width: parent.width
        visible: view.runOk && view.undoPoint !== null && view.undoState === ""
        text: "Tidy archived the configuration it removed, so this can be undone: "
          + "the package is reinstalled first, your settings unpacked on top of it."
        color: view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      FilledButton {
        id: undoButton
        width: parent.width
        visible: view.runOk && view.undoPoint !== null && view.undoState !== "err"
        iconText: "\uf0e2"
        disabled: view.undoState === "busy"
        text: view.undoState === "busy" ? "Putting it back…" : "Undo last uninstall"
        onClicked: view.restoreUndo()
      }

      // The restore's own outcome, kept apart from the removal's so the heading
      // above does not change while the package is being put back.
      Text {
        width: parent.width
        visible: view.undoMessage !== ""
        text: view.undoMessage
        color: view.undoState === "err" ? view.danger : view.success
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Item {
        width: parent.width
        height: Math.max(againButton.height, finishedButton.height)

        Button {
          id: againButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Another"
          iconText: "\uf021"
          foreground: view.fg
          accent: view.accent
          fontFamily: view.fontFamily
          bordered: true
          focusable: false
          onClicked: view.reload()
        }

        FilledButton {
          id: finishedButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf00c"
          text: "Done"
          onClicked: view.dismiss()
        }
      }
    }
  }
}
