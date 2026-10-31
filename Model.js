// No `.pragma library` on purpose: library scripts are cached per QML engine,
// so a plugin update would keep serving the old cleaner list until the whole
// shell restarted. Plain script imports are re-evaluated on plugin reload.

// Cleaner registry. Mirrors the ids understood by scripts/tidy-lib.sh — keep
// the two lists in sync. `kind: "system"` means the cleaner runs through
// pkexec (one prompt for the whole batch), `kind: "user"` runs as you.

var GROUPS = [
  {
    id: "system", title: "System", glyph: "\uf108",
    desc: "Machine-wide files. Tidy asks for your password once for the whole batch."
  },
  {
    id: "user", title: "User", glyph: "\uf007",
    desc: "Your own files. No password needed."
  },
  {
    id: "apps", title: "Applications", glyph: "\uf1b3",
    desc: "Caches and leftovers owned by individual applications."
  }
]

var CLEANERS = [
  // ---------------------------------------------------------------- System
  {
    id: "journal", group: "system", label: "Journal logs", glyph: "\uf15c",
    kind: "system", defaultOn: true,
    desc: "Vacuum the systemd journal, keeping the last 7 days of logs."
  },
  {
    id: "pkgcache", group: "system", label: "Package cache", glyph: "\uf187",
    kind: "system", defaultOn: true,
    desc: "Trim pacman's cached packages down to the most recent version."
  },
  {
    id: "orphans", group: "system", label: "Orphan packages", glyph: "\uf1b3",
    kind: "system", defaultOn: false,
    desc: "Remove packages installed as dependencies that nothing needs anymore."
  },
  {
    id: "coredumps", group: "system", label: "Crash dumps", glyph: "\uf06d",
    kind: "system", defaultOn: true,
    desc: "Delete systemd core dumps and old /var/crash reports."
  },
  {
    id: "tmp", group: "system", label: "Stale temp files", glyph: "\uf017",
    kind: "system", defaultOn: false,
    desc: "Delete entries in /tmp untouched for more than 7 days."
  },

  // ------------------------------------------------------------------ User
  {
    id: "trash", group: "user", label: "Trash", glyph: "\uf1f8",
    kind: "user", defaultOn: true, safe: true,
    desc: "Empty the recycle bin."
  },
  {
    id: "thumbnails", group: "user", label: "Thumbnails", glyph: "\uf03e",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete the thumbnail cache. Images regenerate on demand."
  },
  {
    id: "yaycache", group: "user", label: "Build cache", glyph: "\uf1b2",
    kind: "user", defaultOn: true, safe: true,
    desc: "Remove downloaded sources and built packages from the AUR helper cache."
  },
  {
    id: "recent", group: "user", label: "Recent documents", glyph: "\uf1da",
    kind: "user", defaultOn: true, safe: true,
    desc: "Clear the list of recently opened files."
  },
  {
    id: "omarchy", group: "user", label: "Omarchy leftovers", glyph: "\uf0e2",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete stale .bak backups left behind in your Omarchy config."
  },
  {
    id: "clipboard", group: "user", label: "Clipboard history", glyph: "\uf0ea",
    kind: "user", defaultOn: false,
    desc: "Clear Omarchy's saved clipboard history and copied images."
  },

  // ---------------------------------------------------------- Applications
  {
    id: "firefox", group: "apps", label: "Firefox cache", glyph: "\uf269",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete web and image caches for your Firefox profiles."
  },
  {
    id: "chromium", group: "apps", label: "Chromium cache", glyph: "\uf268",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete the disk cache for Chrome, Chromium, Edge and Vivaldi."
  },
  {
    id: "brave", group: "apps", label: "Brave cache", glyph: "\uf132",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete Brave's web, code and GPU caches. Bookmarks and logins stay."
  },
  {
    id: "helium", group: "apps", label: "Helium cache", glyph: "\uDB82\uDE26",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete Helium's web, code and GPU caches. Bookmarks and logins stay."
  },
  {
    id: "zen", group: "apps", label: "Zen cache", glyph: "\uf06c",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete the Zen browser's cache folders. Bookmarks, logins and sessions stay."
  },
  {
    id: "torbrowser", group: "apps", label: "Tor Browser cache", glyph: "\uf070",
    kind: "user", defaultOn: true, safe: true,
    desc: "Clear Tor Browser's download and update staging. Keeps the signature file the updater needs to verify."
  },
  {
    id: "librewolf", group: "apps", label: "LibreWolf cache", glyph: "\uf1d0",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete LibreWolf's cache folders. Bookmarks, logins and sessions stay."
  },
  {
    id: "tracker", group: "apps", label: "File index caches", glyph: "\uf1c0",
    kind: "user", defaultOn: false,
    desc: "Delete the desktop file-indexer's database and media cache (tracker3). Files are re-indexed on the next pass."
  },
  {
    id: "misetools", group: "apps", label: "mise toolchains", glyph: "\uf0ad",
    kind: "user", defaultOn: true, safe: true,
    desc: "Remove installed tool versions nothing references anymore. Versions your configs require, and tools currently running, are kept."
  },
  {
    id: "ayugram", group: "apps", label: "AyuGram media cache", glyph: "\uf267",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete Telegram media and image caches. Media re-downloads from the cloud when next viewed; login state stays. Skipped while AyuGram is open."
  },
  {
    id: "omarchycache", group: "apps", label: "Omarchy widget caches", glyph: "\uf0e2",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete wallpaper and theme selection thumbnail caches. Thumbnails rebuild on next use."
  },
  {
    id: "chromheadless", group: "apps", label: "Headless temp", glyph: "\uf3a5",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete leftover chromium-headless scratch profiles. Skipped while a headless browser runs."
  },
  {
    id: "mise", group: "apps", label: "mise cache", glyph: "\uf013",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete mise's downloaded tool archives and package store. Installed toolchains are untouched; anything a project needs is re-downloaded on demand."
  },
  {
    id: "npm", group: "apps", label: "npm cache", glyph: "\uf121",
    kind: "user", defaultOn: true, safe: true,
    desc: "Clear npm's package cache and the npx cache. Packages re-fetch when next needed."
  },
  {
    id: "androidstudio", group: "apps", label: "Android Studio caches", glyph: "\uf17b",
    kind: "user", defaultOn: true, safe: true,
    desc: "Delete IDE index caches. Automatically skipped while Android Studio is open."
  },
  {
    id: "docker", group: "apps", label: "Docker", glyph: "\uf21a",
    kind: "system", defaultOn: true,
    desc: "Remove stopped containers, dangling images and build cache. Named volumes are kept."
  },
  {
    id: "flatpak", group: "apps", label: "Flatpak", glyph: "\uf1b3",
    kind: "user", defaultOn: true,
    desc: "Uninstall Flatpak runtimes and applications nothing depends on any more."
  }
]

function byId(id) {
  for (var i = 0; i < CLEANERS.length; i++)
    if (CLEANERS[i].id === id) return CLEANERS[i]
  return null
}

function cleanersIn(groupId) {
  var out = []
  for (var i = 0; i < CLEANERS.length; i++)
    if (CLEANERS[i].group === groupId) out.push(CLEANERS[i])
  return out
}

// The conservative set — caches, thumbnails, the trash, browser caches. Mirrors
// TIDY_SAFE_CLEANERS in scripts/tidy-lib.sh, which is what actually runs; this
// copy exists only so the button can put a number on itself before you press
// it. Never send these ids to tidy-clean — pass --safe and let the backend
// decide, so a stale front end can never widen what a one-click button does.
function safeIds() {
  var out = []
  for (var i = 0; i < CLEANERS.length; i++)
    if (CLEANERS[i].safe === true) out.push(CLEANERS[i].id)
  return out
}

// How much the conservative set would free, given a completed scan.
function safeBytes(scan) {
  var ids = safeIds()
  var total = 0
  for (var i = 0; i < ids.length; i++) {
    var entry = scan ? scan[ids[i]] : null
    if (!entry || !entry.available) continue
    total += Number(entry.bytes) || 0
  }
  return total
}

function groupTitle(groupId) {
  for (var i = 0; i < GROUPS.length; i++)
    if (GROUPS[i].id === groupId) return GROUPS[i].title
  return groupId
}

// 1536 -> "1.5 KB". Skips decimals for small byte counts so rows stay tidy.
function formatBytes(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) {
    n = n / 1024
    i++
  }
  var digits = i === 0 ? 0
    : (n < 10 && Math.abs(n - Math.round(n)) > 0.0001 ? 1 : 0)
  return n.toFixed(digits) + " " + units[i]
}

function formatCount(value) {
  var n = Math.round(Number(value) || 0)
  if (n <= 0) return "0"
  if (n < 1000) return String(n)
  if (n < 1000000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k"
  return (n / 1000000).toFixed(1) + "M"
}

// Short status text for a row's right-hand side, given a scan entry.
function sizeLabel(entry, fallbackCount) {
  if (!entry) return "…"
  if (Number(entry.available) !== 1) return entry.reason || "unavailable"
  var bytes = Number(entry.bytes) || 0
  if (bytes > 0) return formatBytes(bytes)
  var files = Number(entry.files) || 0
  if (files > 0) return formatCount(files) + " items"
  if (fallbackCount) return "—"
  return "—"
}
