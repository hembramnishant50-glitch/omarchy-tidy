<div align="center">

# 🧹 Tidy

**A BleachBit-style system cleaner for [Omarchy](https://omarchy.org).**

*Reclaim disk space from logs, caches, packages and leftovers — honestly measured, carefully guarded, one click away.*

[![Version](https://img.shields.io/badge/version-1.0.0-blue)](https://github.com/hembramnishant50-glitch/omarchy-tidy)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Omarchy%20%7C%20Arch%20Linux-red)](https://omarchy.org)
[![Language](https://img.shields.io/badge/shell-bash%20%2B%20QML-yellow)](#architecture)

</div>

---

## ✨ What it does

Tidy is an Omarchy bar widget + panel plugin that knows where the megabytes are hiding — pacman's package cache, the systemd journal, browser caches, AUR build leftovers, npm/mise tool stores, Docker and Flatpak dead weight — and cleans only what is safe to delete, showing you the *honest* number of bytes before and after.

<div align="center">

| Slot | What you see |
|:---:|:---|
| **Bar widget** | Reclaimable space + a one-click **Safe Clean** button |
| **Clean tab** | 20 grouped cleaners, preview or run, with live totals |
| **Apps tab** | Scan your system and uninstall packages with real disk accounting |
| **Space tab** | Root-level disk overview at a glance |
| **History tab** | Every run logged, with undo where it's possible |

</div>

## 🛠 The cleaners

### System (runs via one `pkexec` prompt for the whole batch)

| Cleaner | Removes | Keeps |
|:---|:---|:---|
| **Journal logs** | System logs older than 7 days | The last week |
| **Package cache** | Old versions of installed packages **+ archives of packages you've uninstalled** (`paccache -rk1` + `-ruk0`) | One version of every installed package — rollback stays possible |
| **Orphan packages** | Dependencies nothing needs any more | Opt-in, never automatic |
| **Crash dumps** | `systemd-coredump` and `/var/crash` | — |
| **Stale temp files** | `/tmp` entries older than 7 days | Anything recent |

### User (runs as you, no password)

| Cleaner | Removes |
|:---|:---|
| **Trash** | Empties `~/.local/share/Trash` |
| **Thumbnails** | Rebuilt on demand by your file manager |
| **Build cache** | `yay` / `paru` build leftovers |
| **Recent documents** | Recently-opened lists |
| **Omarchy leftovers** | Stale `.bak` config backups |
| **Clipboard history** | Saved clipboard entries and copied images (opt-in) |

### Applications

| Cleaner | Removes | Guard rails |
|:---|:---|:---|
| **Firefox / Chromium / Brave / Helium** | web, code and GPU caches | Bookmarks, logins, sessions stay |
| **mise cache** | Downloaded tool archives + its npm package store | Installed toolchains in `~/.local/share/mise` are never touched |
| **npm cache** | `~/.npm/_cacache` + npx cache | Packages re-fetch when next needed |
| **Android Studio** | IDE index caches | **Auto-skipped while the IDE is open** |
| **Docker** | Stopped containers, dangling images, build cache | Named volumes are kept unless you ask |
| **Flatpak** | Runtimes and apps nothing depends on | Opt-out dependencies are honoured |

## 🔒 Safety by design

- **Previews first** — every cleaner has a dry run; `tidy-clean --preview` asks for zero passwords and deletes nothing.
- **The Safe set** — the one-click button and the overnight timer only ever run cleaners that need no root and hold nothing but regenerable data (`TIDY_SAFE_CLEANERS`). A scheduled job can never answer a polkit prompt, and *"free up some space"* is not consent to lose the clipboard.
- **One password, whole batch** — system cleaners are collected and executed in a single `pkexec bash -c`, so Omarchy's in-shell polkit agent prompts exactly once no matter how many system cleaners you selected.
- **Honest accounting** — sizes are measured before *and* after; what a run reports as freed is what actually went away. A clean 4 GB package cache reports `0 bytes`, not `4 GB`.
- **Undo where possible** — the history log carries an undo list so recent deletions can be restored.
- **Shred option** — `--shred` overwrites files before unlinking for the paranoid.

## 📦 Install

```bash
git clone https://github.com/hembramnishant50-glitch/omarchy-tidy ~/.config/omarchy/plugins/nishant.tidy
# then: pick Tidy in your bar widget settings (may need to restart the shell)
```

Dependencies: `bash`, `python3`, `pacman`, `polkit`/`pkexec` — all standard on Omarchy.
Optional: `expac`, `docker`, `flatpak`, `mise`, `npm`.

## ⌨️ CLI

The panel is a thin skin over plain bash scripts — everything is scriptable:

```bash
# what could be reclaimed, as JSON
tidy-scan

# dry run (no root needed, changes nothing)
tidy-clean --preview --safe

# run only the passwordless safe set
tidy-clean --safe

# run specific cleaners (system ones ask for one password)
tidy-clean pkgcache journal

# app discovery + uninstall with disk accounting
tidy-uninstall preview code
tidy-uninstall scan --limit 10

# history, undo list, scheduled auto-clean status
tidy-state history
tidy-schedule status
tidy-schedule enable 03:00 daily
```

## 🧬 Architecture

```
┌─────────────────── Omarchy shell ───────────────────┐
│  BarWidget.qml ─── Panel.qml ─── Model.js (manifest) │
│   └ four views: Clean · Apps · Space · History       │
└──────────────┬──────────────────────────────────────┘
               │ QProcess
┌──────────────▼──────────────────────────────────────┐
│  scripts/                                            │
│   tidy-scan      read-only measurement → JSON        │
│   tidy-clean     dry-run/decryptive pass → RESULT lines│
│   tidy-uninstall package scanner / uninstaller        │
│   tidy-state     history + undo store (Python)        │
│   tidy-schedule  auto-clean timer                     │
│   tidy-lib.sh    all cleaner definitions, one per id  │
└──────────────────────────────────────────────────────┘
```

Every cleaner is four small bash functions: `measure_`, `files_`, `avail_` (with a human-readable reason when it can't run) and `clean_`. Adding a cleaner is adding one stanza; the panel, the scheduler and the history find it automatically.

## ❓ FAQ

**Is the Safe Clean really safe to run unattended?**
Yes — it never elevates, only touches regenerable caches, and the scheduler uses exactly that set by default.

**Why did my package cache show 4 GB that a clean never freed?**
Because the raw directory size isn't the reclaimable size — pacman deliberately keeps one copy of every installed package. Tidy measures the *deletable* share via `paccache` dry runs, so the number you see is the number you get.

**Can I add my own cleaner?**
Copy a stanza in `scripts/tidy-lib.sh`, add four functions, register the id in `TIDY_CLEANERS` (and `Model.js` for the UI row). That's it.

## 📄 License

[MIT](LICENSE) — free to use, hack, and fork.
