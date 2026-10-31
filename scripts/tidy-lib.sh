#!/usr/bin/env bash
# tidy-lib.sh — measurement + cleanup routines shared by tidy-scan and tidy-clean.
#
# Every cleaner id in the list below must provide four functions:
#   measure_<id>  -> apparent size in bytes on stdout
#   files_<id>    -> number of files / items on stdout
#   avail_<id>    -> "1" when usable, or "0 <short reason>"
#   clean_<id>    -> performs the cleanup, exit 0 on success
#
# Ids must match CLEANERS in ../Model.js.

TIDY_CLEANERS="journal pkgcache orphans coredumps tmp trash thumbnails yaycache recent omarchy clipboard firefox chromium brave helium zen torbrowser librewolf mise npm androidstudio tracker misetools ayugram omarchycache chromheadless docker flatpak"

# The conservative set: none of these need root, and none of them hold
# anything that is not rebuilt on demand. This is what the one-click button
# and the background timer run — a scheduled job cannot answer a polkit
# prompt, and "free up some space" is not consent to lose the clipboard.
TIDY_SAFE_CLEANERS="trash thumbnails yaycache recent omarchy firefox chromium brave helium zen torbrowser librewolf mise npm androidstudio misetools ayugram omarchycache chromheadless"

TIDY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TIDY_STATE="$TIDY_LIB_DIR/tidy-state"

TIDY_HOME="${TIDY_HOME:-${HOME:-/root}}"
TIDY_SHRED="${TIDY_SHRED:-0}"
# `docker system prune` spares volumes; only ask for them explicitly.
TIDY_DOCKER_VOLUMES="${TIDY_DOCKER_VOLUMES:-0}"

TIDY_PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

tidy_kind() {
  case "$1" in
    journal | pkgcache | orphans | coredumps | tmp | docker) echo system ;;
    *) echo user ;;
  esac
}

# ---------------------------------------------------------------------------
# the ignore list
# ---------------------------------------------------------------------------
# "never touch ~/.cache/foo" has to mean one thing everywhere, so a path on
# the list is neither measured nor cleaned. Read once per process; the checks
# below are then pure string comparisons.

_TIDY_IGNORE=()
_TIDY_IGNORE_READY=0

_tidy_load_ignore() {
  [ "$_TIDY_IGNORE_READY" = 1 ] && return 0
  _TIDY_IGNORE_READY=1
  [ -x "$TIDY_STATE" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && _TIDY_IGNORE+=("${line%/}")
  done < <("$TIDY_STATE" ignore-list --raw 2>/dev/null)
  return 0
}

# 0 when the path is on the list, or lives inside something that is.
_tidy_ignored() {
  local p="${1%/}"
  [ -n "$p" ] || return 1
  if [ "${#_TIDY_IGNORE[@]}" -eq 0 ]; then
    _tidy_load_ignore
    [ "${#_TIDY_IGNORE[@]}" -eq 0 ] && return 1
  fi
  local i
  for i in "${_TIDY_IGNORE[@]}"; do
    case "$p" in
      "$i" | "$i"/*) return 0 ;;
    esac
  done
  return 1
}

# Drop ignored paths from a newline- or NUL-delimited stream.
_tidy_filter_ignored() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _tidy_ignored "$p" && continue
    printf '%s\n' "$p"
  done
}

_tidy_filter_ignored_nul() {
  local p
  while IFS= read -r -d '' p; do
    _tidy_ignored "$p" && continue
    printf '%s\0' "$p"
  done
  # GNU find always terminates with NUL, but a hand-fed stream may not; keep
  # the last entry instead of silently dropping it.
  if [ -n "${p:-}" ]; then
    _tidy_ignored "$p" || printf '%s\0' "$p"
  fi
}

# ---------------------------------------------------------------------------
# trash
# ---------------------------------------------------------------------------
# Move a path to the freedesktop trash instead of deleting it. The uninstaller
# uses this for its leftover sweep, where the match is a guess: a wrong guess
# in the trash is a nuisance, a wrong guess through rm -rf is a lost file.
# Returns non-zero when the path is outside the home directory, or when the
# trash is on another filesystem, so the caller can fall back to a real delete.

_tidy_trash() {
  local src="${1%/}"
  [ -e "$src" ] || return 1
  case "$src" in "$TIDY_HOME"/*) ;; *) return 1 ;; esac

  local trash="$TIDY_HOME/.local/share/Trash"
  local files="$trash/files" info="$trash/info"
  mkdir -p "$files" "$info" 2>/dev/null || return 1

  local dsrc dtrash
  dsrc="$(stat -c %d -- "$(dirname -- "$src")" 2>/dev/null)"
  dtrash="$(stat -c %d -- "$files" 2>/dev/null)"
  [ -n "$dsrc" ] && [ "$dsrc" = "$dtrash" ] || return 1

  local base dest n=0
  base="$(basename -- "$src")"
  dest="$files/$base"
  while [ -e "$dest" ]; do
    n=$((n + 1))
    dest="$files/$base.$n"
  done
  mv -- "$src" "$dest" 2>/dev/null || return 1

  local rel="${dest#"$files"/}" encoded
  if [ -n "$TIDY_PY" ]; then
    encoded="$(printf '%s' "$src" | "$TIDY_PY" -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.stdin.read(),safe="/"))' 2>/dev/null)"
  fi
  [ -n "$encoded" ] || encoded="$(printf '%s' "$src" | sed 's/%/%25/g; s/ /%20/g')"
  {
    printf '[Trash Info]\n'
    printf 'Path=%s\n' "$encoded"
    printf 'DeletionDate=%s\n' "$(date +%Y-%m-%dT%H:%M:%S)"
  } >"$info/$rel.trashinfo" 2>/dev/null
  return 0
}

# "4.6 GB" for notifications and totals.
_tidy_human() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ")
    i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]
    else if (b >= 100) printf "%.0f %s", b, u[i]
    else printf "%.1f %s", b, u[i]
  }'
}

# ---------------------------------------------------------------------------
# low-level helpers
# ---------------------------------------------------------------------------

# Human size like "40M", "1.2G", "512B" -> bytes.
_hb() {
  local s="${1:-0}" u n
  s="${s//[^0-9KMGTPkmgtp.]/}"
  s="${s%B}"
  [ -n "$s" ] || { echo 0; return; }
  u="${s: -1}"
  n="${s%?}"
  case "$u" in
    K | k) awk -v n="$n" 'BEGIN { printf "%d", n * 1024 }' ;;
    M | m) awk -v n="$n" 'BEGIN { printf "%d", n * 1048576 }' ;;
    G | g) awk -v n="$n" 'BEGIN { printf "%d", n * 1073741824 }' ;;
    T | t) awk -v n="$n" 'BEGIN { printf "%d", n * 1099511627776 }' ;;
    *) awk -v n="$s" 'BEGIN { printf "%d", n + 0 }' ;;
  esac
}

_path_bytes() {
  local p="$1" out
  [ -e "$p" ] || { echo 0; return; }
  # du can exit non-zero after printing a usable total (unreadable subdirs),
  # so parse the output rather than trusting the status.
  out="$(du -sb -- "$p" 2>/dev/null | tail -1)"
  out="${out%%[[:space:]]*}"
  case "$out" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$out" ;;
  esac
}

# Apparent bytes for every argument that exists.
_glob_bytes() {
  local total=0 p
  for p in "$@"; do
    [ -e "$p" ] || continue
    total=$((total + $(_path_bytes "$p")))
  done
  echo "$total"
}

# Sum apparent bytes of NUL-separated paths on stdin.
sum_bytes_nul() {
  local total=0 p b
  while IFS= read -r -d '' p; do
    b="$(_path_bytes "$p")"
    total=$((total + ${b:-0}))
  done
  if [ -n "${p:-}" ]; then
    b="$(_path_bytes "$p")"
    total=$((total + ${b:-0}))
  fi
  echo "$total"
}

# Sum apparent bytes of newline-separated paths on stdin.
sum_bytes_lines() {
  local total=0 p b
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    b="$(_path_bytes "$p")"
    total=$((total + ${b:-0}))
  done
  echo "$total"
}

_count_lines() {
  local n=0 l
  while IFS= read -r l; do
    [ -n "$l" ] && n=$((n + 1))
  done
  echo "$n"
}

# Single-pass overwrite of regular files under each path, for the "shred"
# option. Deleting through shred removes the file, so the caller can follow
# with a plain rm to clear whatever directories remain.
_tidy_wipe() {
  [ "$TIDY_SHRED" = 1 ] || return 0
  command -v shred >/dev/null 2>&1 || return 0
  _tidy_load_ignore
  local p f
  for p in "$@"; do
    [ -e "$p" ] || continue
    _tidy_ignored "$p" && continue
    if [ "${#_TIDY_IGNORE[@]}" -eq 0 ]; then
      find "$p" -type f -exec shred -u -n 1 -- {} + 2>/dev/null
    else
      while IFS= read -r -d '' f; do
        _tidy_ignored "$f" && continue
        shred -u -n 1 -- "$f" 2>/dev/null
      done < <(find "$p" -type f -print0 2>/dev/null)
    fi
  done
  return 0
}

# Remove the contents of each directory, keeping the directory itself.
_clear_dir() {
  local d entry
  for d in "$@"; do
    [ -d "$d" ] || continue
    _tidy_ignored "$d" && continue
    if [ "${#_TIDY_IGNORE[@]}" -eq 0 ] && [ "$_TIDY_IGNORE_READY" = 1 ]; then
      find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
      continue
    fi
    _tidy_load_ignore
    while IFS= read -r -d '' entry; do
      _tidy_ignored "$entry" && continue
      rm -rf -- "$entry" 2>/dev/null
    done < <(find "$d" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  done
  return 0
}

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# System — journal
# ---------------------------------------------------------------------------
measure_journal() {
  local out num
  out="$(journalctl --disk-usage 2>/dev/null)" || { echo 0; return; }
  num="$(printf '%s' "$out" | grep -oE '[0-9]+([.,][0-9]+)?[[:space:]]*[KMGTP]?B?' | head -1)"
  [ -n "$num" ] || { echo 0; return; }
  _hb "$num"
}
files_journal() { echo 0; }
avail_journal() {
  if command -v journalctl >/dev/null 2>&1; then echo 1; else echo "0 journalctl missing"; fi
}
clean_journal() {
  journalctl --rotate >/dev/null 2>&1
  journalctl --vacuum-time=7d >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# System — pacman package cache
# ---------------------------------------------------------------------------
# Reclaimable pkgcache estimate, one dry run: "<candidates> <bytes>" or
# nothing when the summary line cannot be parsed. The dry runs need no
# root, so this is honest in the panel scan too.
_pkgcache_dryrun() {
  local out cand saved
  out="$(paccache $1 2>/dev/null | tail -3)"
  cand="$(printf '%s\n' "$out" | sed -n 's/.*finished dry run:[[:space:]]\{1,\}\([0-9][0-9]*\) candidates.*/\1/p' | tail -1)"
  saved="$(printf '%s\n' "$out" | sed -n 's/.*disk space saved:[[:space:]]\{1,\}//p' | tail -1)"
  saved="${saved%)}"
  [ -n "$cand" ] && [ -n "$saved" ] || return 1
  printf '%d %d\n' "$cand" "$(_hb "$saved")" || return 1
}

# The directory size is not the reclaimable size: paccache keeps one copy
# of every installed package on purpose, so a multi-GB cache can be
# perfectly clean. Showing the raw size made the panel promise space that
# a run of the cleaner could never free. What the dry runs would delete —
# old versions of installed packages plus everything belonging to
# uninstalled ones — is what a run actually frees.
measure_pkgcache() {
  command -v paccache >/dev/null 2>&1 || { echo 0; return; }
  local t=0 r
  for a in -dk1 -duk0; do
    # shellcheck disable=SC2086
    if r="$(_pkgcache_dryrun "$a")"; then t=$((t + ${r##* })); fi
  done
  echo "$t"
}
files_pkgcache() {
  command -v paccache >/dev/null 2>&1 || { echo 0; return; }
  local n=0 r
  for a in -dk1 -duk0; do
    # shellcheck disable=SC2086
    if r="$(_pkgcache_dryrun "$a")"; then n=$((n + ${r%% *})); fi
  done
  echo "$n"
}
avail_pkgcache() {
  if [ ! -d /var/cache/pacman/pkg ]; then echo "0 no pacman cache"; return; fi
  if ! command -v paccache >/dev/null 2>&1; then echo "0 paccache missing"; return; fi
  echo 1
}
clean_pkgcache() {
  command -v paccache >/dev/null 2>&1 || return 1
  # -rk1 trims every package down to one cached build. It is not the whole
  # job: paccache decides what to keep per package found in the cache, and an
  # uninstalled package keeps its one version too — so an uninstall leaves its
  # archive behind forever. -ruk0 targets the uninstalled alone and keeps
  # nothing of them; together the cache shrinks to what the installed
  # packages actually need. The two cases do not overlap, so each is run for
  # its own exit status.
  local rc=0
  paccache -rk1 >/dev/null 2>&1 || rc=1
  paccache -ruk0 >/dev/null 2>&1 || rc=1
  return $rc
}

# ---------------------------------------------------------------------------
# System — orphan packages
# ---------------------------------------------------------------------------
_orphan_pkgs() { pacman -Qtdq 2>/dev/null; }

measure_orphans() {
  local pkgs
  pkgs="$(_orphan_pkgs)"
  [ -n "$pkgs" ] || { echo 0; return; }
  printf '%s\n' "$pkgs" | xargs -r pacman -Qi 2>/dev/null | awk -F': ' '
    /^Installed Size/ {
      split($2, a, " "); v = a[1] + 0; u = a[2]
      if (u == "KiB") b += v * 1024
      else if (u == "MiB") b += v * 1048576
      else if (u == "GiB") b += v * 1073741824
      else b += v
    }
    END { printf "%d", b + 0 }'
}
files_orphans() { _orphan_pkgs | _count_lines; }
avail_orphans() {
  if command -v pacman >/dev/null 2>&1; then echo 1; else echo "0 pacman missing"; fi
}
clean_orphans() {
  local pkgs
  pkgs="$(_orphan_pkgs)"
  [ -n "$pkgs" ] || return 0
  # shellcheck disable=SC2086
  pacman -Rns --noconfirm $pkgs >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# System — crash dumps
# ---------------------------------------------------------------------------
measure_coredumps() {
  { _path_bytes /var/lib/systemd/coredump; _path_bytes /var/crash; } | awk '{ s += $1 } END { print s + 0 }'
}
files_coredumps() {
  find /var/lib/systemd/coredump /var/crash -maxdepth 1 -type f 2>/dev/null | _count_lines
}
avail_coredumps() {
  if command -v coredumpctl >/dev/null 2>&1; then echo 1; else echo "0 coredumpctl missing"; fi
}
clean_coredumps() {
  coredumpctl --vacuum-time=1d >/dev/null 2>&1
  _clear_dir /var/lib/systemd/coredump /var/crash
}

# ---------------------------------------------------------------------------
# System — stale temp files
# ---------------------------------------------------------------------------
measure_tmp() {
  find /tmp -mindepth 1 -maxdepth 1 -mtime +7 -print0 2>/dev/null |
    _tidy_filter_ignored_nul | sum_bytes_nul
}
files_tmp() {
  find /tmp -mindepth 1 -maxdepth 1 -mtime +7 2>/dev/null | _tidy_filter_ignored | _count_lines
}
avail_tmp() { echo 1; }
clean_tmp() {
  find /tmp -mindepth 1 -maxdepth 1 -mtime +7 -print0 2>/dev/null |
    _tidy_filter_ignored_nul | xargs -0 -r rm -rf -- 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# User — trash
# ---------------------------------------------------------------------------
measure_trash() {
  _glob_bytes "$TIDY_HOME/.local/share/Trash/files" "$TIDY_HOME/.local/share/Trash/info"
}
files_trash() {
  find "$TIDY_HOME/.local/share/Trash/files" -mindepth 1 -maxdepth 1 2>/dev/null | _count_lines
}
avail_trash() {
  if [ -d "$TIDY_HOME/.local/share/Trash" ]; then echo 1; else echo "0 no trash directory"; fi
}
clean_trash() {
  _tidy_wipe "$TIDY_HOME/.local/share/Trash/files"
  _clear_dir "$TIDY_HOME/.local/share/Trash/files" "$TIDY_HOME/.local/share/Trash/info"
}

# ---------------------------------------------------------------------------
# User — thumbnail cache
# ---------------------------------------------------------------------------
measure_thumbnails() { _path_bytes "$TIDY_HOME/.cache/thumbnails"; }
files_thumbnails() {
  find "$TIDY_HOME/.cache/thumbnails" -type f 2>/dev/null | _count_lines
}
avail_thumbnails() {
  if [ -d "$TIDY_HOME/.cache/thumbnails" ]; then echo 1; else echo "0 no thumbnail cache"; fi
}
clean_thumbnails() {
  _tidy_wipe "$TIDY_HOME/.cache/thumbnails"
  _clear_dir "$TIDY_HOME/.cache/thumbnails"
}

# ---------------------------------------------------------------------------
# User — AUR helper build cache
# ---------------------------------------------------------------------------
measure_yaycache() { _glob_bytes "$TIDY_HOME/.cache/yay" "$TIDY_HOME/.cache/paru"; }
files_yaycache() {
  find "$TIDY_HOME/.cache/yay" "$TIDY_HOME/.cache/paru" -mindepth 1 -maxdepth 1 2>/dev/null | _count_lines
}
avail_yaycache() {
  if [ -d "$TIDY_HOME/.cache/yay" ] || [ -d "$TIDY_HOME/.cache/paru" ]; then
    echo 1
  else
    echo "0 no AUR build cache"
  fi
}
clean_yaycache() {
  _tidy_wipe "$TIDY_HOME/.cache/yay" "$TIDY_HOME/.cache/paru"
  _clear_dir "$TIDY_HOME/.cache/yay" "$TIDY_HOME/.cache/paru"
}

# ---------------------------------------------------------------------------
# User — recently-used list
# ---------------------------------------------------------------------------
_recent_file() { echo "$TIDY_HOME/.local/share/recently-used.xbel"; }
measure_recent() { _path_bytes "$(_recent_file)"; }
files_recent() {
  if [ -s "$(_recent_file)" ]; then echo 1; else echo 0; fi
}
avail_recent() {
  if [ -f "$(_recent_file)" ]; then echo 1; else echo "0 no recent-files list"; fi
}
clean_recent() {
  : >"$(_recent_file)" 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# User — stale Omarchy config backups
# ---------------------------------------------------------------------------
_tidy_bak_list() {
  find "$TIDY_HOME/.config/omarchy" "$TIDY_HOME/.config/hypr" \
    -maxdepth 3 -name '*.bak.*' 2>/dev/null | _tidy_filter_ignored
}
measure_omarchy() { _tidy_bak_list | sum_bytes_lines; }
files_omarchy() { _tidy_bak_list | _count_lines; }
avail_omarchy() { echo 1; }
clean_omarchy() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _tidy_wipe "$p"
    rm -rf -- "$p" 2>/dev/null
  done <<<"$(_tidy_bak_list)"
  return 0
}

# ---------------------------------------------------------------------------
# User — clipboard history
# ---------------------------------------------------------------------------
_clip_file() { echo "$TIDY_HOME/.local/state/omarchy/clipboard-history.json"; }
_clip_images() { echo "$TIDY_HOME/.local/state/omarchy/clipboard-images"; }
measure_clipboard() { _glob_bytes "$(_clip_file)" "$(_clip_images)"; }
files_clipboard() {
  find "$(_clip_images)" -type f 2>/dev/null | _count_lines
}
avail_clipboard() {
  if [ -e "$(_clip_file)" ] || [ -d "$(_clip_images)" ]; then
    echo 1
  else
    echo "0 no clipboard history"
  fi
}
clean_clipboard() {
  _tidy_wipe "$(_clip_images)"
  rm -rf -- "$(_clip_images)" 2>/dev/null
  printf '[]\n' >"$(_clip_file)" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Applications — Firefox cache
# ---------------------------------------------------------------------------
# Firefox's derived caches, and only those: cache2 is the web cache, startupCache
# and thumbnails are rebuilt on the next launch. `safebrowsing` lives beside them
# and is deliberately left alone — deleting it would make the next few minutes of
# browsing less safe, not just slower.
_firefox_dirs() {
  find "$TIDY_HOME/.cache/mozilla" "$TIDY_HOME/.mozilla" \
    -maxdepth 5 -type d \
    \( -name cache2 -o -name startupCache -o -name thumbnails \) 2>/dev/null \
    | _tidy_filter_ignored
}
measure_firefox() { _firefox_dirs | sum_bytes_lines; }
files_firefox() { _firefox_dirs | _count_lines; }
avail_firefox() {
  if [ -d "$TIDY_HOME/.mozilla" ] || [ -d "$TIDY_HOME/.cache/mozilla" ]; then
    echo 1
  else
    echo "0 Firefox not installed"
  fi
}
clean_firefox() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    rm -rf -- "$d" 2>/dev/null
  done <<<"$(_firefox_dirs)"
  return 0
}

# ---------------------------------------------------------------------------
# Applications — Chromium-family cache
# ---------------------------------------------------------------------------
_chromium_dirs() {
  {
    find "$TIDY_HOME/.cache" -maxdepth 2 -type d \
      \( -name google-chrome -o -name chromium \
      -o -name microsoft-edge -o -name vivaldi -o -name opera \) 2>/dev/null
    find "$TIDY_HOME/.config" -maxdepth 5 -type d \
      \( -path '*google-chrome*/Cache' -o -path '*chromium*/Cache' \
      -o -path '*microsoft-edge*/Cache' \
      -o -path '*vivaldi*/Cache' \) 2>/dev/null
  } | _tidy_filter_ignored
}
measure_chromium() { _chromium_dirs | sum_bytes_lines; }
files_chromium() { _chromium_dirs | _count_lines; }
avail_chromium() {
  if [ -d "$TIDY_HOME/.config/google-chrome" ] || [ -d "$TIDY_HOME/.config/chromium" ] \
    || [ -d "$TIDY_HOME/.cache/google-chrome" ] || [ -d "$TIDY_HOME/.cache/chromium" ]; then
    echo 1
  else
    echo "0 Chromium not installed"
  fi
}
clean_chromium() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    rm -rf -- "$d" 2>/dev/null
  done <<<"$(_chromium_dirs)"
  return 0
}

# ---------------------------------------------------------------------------
# Applications — Chromium-family browser caches with their own root
# ---------------------------------------------------------------------------
# Brave and Helium keep the stock Chromium cache layout, but under their own
# cache root rather than a shared one, so they get their own cleaners (and
# their own reported sizes). Only the cache subtrees are touched — profiles,
# logins, bookmarks and history live under ~/.config and are never removed.
_browser_cache_dirs() {
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" -maxdepth 3 -type d \
    \( -name 'Cache' -o -name 'Code Cache' -o -name 'GPUCache' \
    -o -name 'DawnGraphiteCache' -o -name 'DawnWebGPUCache' \
    -o -name 'ShaderCache' -o -name 'GrShaderCache' \
    -o -name 'component_crx_cache' -o -name 'extensions_crx_cache' \
    -o -name 'Media Cache' -o -name 'ScriptCache' \) 2>/dev/null | _tidy_filter_ignored
}

clean_browser_root() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    rm -rf -- "$d" 2>/dev/null
  done <<<"$(_browser_cache_dirs "$1")"
  return 0
}

_brave_root() { echo "$TIDY_HOME/.cache/BraveSoftware"; }
measure_brave() { _browser_cache_dirs "$(_brave_root)" | sum_bytes_lines; }
files_brave() { _browser_cache_dirs "$(_brave_root)" | _count_lines; }
avail_brave() {
  if [ -d "$TIDY_HOME/.config/BraveSoftware" ] || [ -d "$(_brave_root)" ]; then
    echo 1
  else
    echo "0 Brave not installed"
  fi
}
clean_brave() { clean_browser_root "$(_brave_root)"; }

_helium_root() { echo "$TIDY_HOME/.cache/net.imput.helium"; }
measure_helium() { _browser_cache_dirs "$(_helium_root)" | sum_bytes_lines; }
files_helium() { _browser_cache_dirs "$(_helium_root)" | _count_lines; }
avail_helium() {
  if [ -d "$TIDY_HOME/.config/net.imput.helium" ] || [ -d "$(_helium_root)" ]; then
    echo 1
  else
    echo "0 Helium not installed"
  fi
}
clean_helium() { clean_browser_root "$(_helium_root)"; }

# ---------------------------------------------------------------------------
# Applications — Gecko-family browser caches (Zen, LibreWolf, Tor Browser)
# ---------------------------------------------------------------------------
# Firefox forks cache under lowercase dirs (cache2, startupCache,
# thumbnails) instead of the chromium-style names, so they need their own
# dir finder. The base Firefox deal (~/.cache/mozilla) is already covered
# by the firefox cleaner above; only the forks need this helper.
_gecko_cache_dirs() {
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" -maxdepth 4 -type d \
    \( -name cache2 -o -name startupCache -o -name thumbnails \) 2>/dev/null \
    | _tidy_filter_ignored
}
clean_gecko_root() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    rm -rf -- "$d" 2>/dev/null
  done <<<"$(_gecko_cache_dirs "$1")"
  return 0
}

_zen_root() { echo "$TIDY_HOME/.cache/zen"; }
measure_zen() { _gecko_cache_dirs "$(_zen_root)" | sum_bytes_lines; }
files_zen() { _gecko_cache_dirs "$(_zen_root)" | _count_lines; }
avail_zen() {
  if [ -d "$(_zen_root)" ]; then echo 1; else echo "0 Zen not installed"; fi
}
clean_zen() { clean_gecko_root "$(_zen_root)"; }

_librewolf_root() { echo "$TIDY_HOME/.cache/librewolf"; }
measure_librewolf() { _gecko_cache_dirs "$(_librewolf_root)" | sum_bytes_lines; }
files_librewolf() { _gecko_cache_dirs "$(_librewolf_root)" | _count_lines; }
avail_librewolf() {
  if [ -d "$(_librewolf_root)" ]; then echo 1; else echo "0 LibreWolf not installed"; fi
}
clean_librewolf() { clean_gecko_root "$(_librewolf_root)"; }

# Tor Browser: only the update/download staging area. The .gpg bundle
# signature next to it is kept so the updater keeps its verification chain.
_torbrowser_dir() { echo "$TIDY_HOME/.cache/torbrowser/download"; }
measure_torbrowser() { _path_bytes "$(_torbrowser_dir)"; }
files_torbrowser() {
  find "$(_torbrowser_dir)" -mindepth 1 -maxdepth 1 2>/dev/null | _count_lines
}
avail_torbrowser() {
  if [ -d "$TIDY_HOME/.cache/torbrowser" ]; then echo 1; else echo "0 Tor Browser not installed"; fi
}
clean_torbrowser() {
  _tidy_wipe "$(_torbrowser_dir)"
  _clear_dir "$(_torbrowser_dir)"
}

# ---------------------------------------------------------------------------
# Applications — desktop file index (tracker)
# ---------------------------------------------------------------------------
# ~/.cache/tracker3 holds the file-indexer's database and extracted media
# cache. Deleting it means a reindex on next mining pass — noticeable but
# harmless, so this one is opt-in rather than part of the safe set.
_tracker_root() { echo "$TIDY_HOME/.cache/tracker3"; }
measure_tracker() { _path_bytes "$(_tracker_root)"; }
files_tracker() {
  find "$(_tracker_root)" -mindepth 1 -maxdepth 1 2>/dev/null | _count_lines
}
avail_tracker() {
  if [ -d "$(_tracker_root)" ]; then echo 1; else echo "0 no tracker cache"; fi
}
clean_tracker() {
  _tidy_wipe "$(_tracker_root)"
  _clear_dir "$(_tracker_root)"
}

# ---------------------------------------------------------------------------
# Applications — unused mise toolchains
# ---------------------------------------------------------------------------
# ~/.local/share/mise/installs keeps every version ever installed. mise's
# own `prune --tools` decides what is unused: it checks every tracked config
# (so required versions stay) and skips versions running processes are
# still using — safer than this script guessing. The dry run doubles as the
# honest meter; its detail lines go to stderr and print "~"-prefixed paths.
_misetools_pruned_paths() {
  mise prune --dry-run --tools 2>&1 |
    sed -n 's/.*[[:space:]]remove[[:space:]]//p' |
    sed "s|^~|$HOME/|" |
    sort -u
}
measure_misetools() {
  command -v mise >/dev/null 2>&1 || { echo 0; return; }
  _misetools_pruned_paths | sum_bytes_lines
}
files_misetools() {
  command -v mise >/dev/null 2>&1 || { echo 0; return; }
  mise prune --dry-run --tools 2>&1 | grep -c " is prunable: "
}
avail_misetools() {
  command -v mise >/dev/null 2>&1 || { echo "0 mise not installed"; return; }
  if [ -d "$TIDY_HOME/.local/share/mise" ]; then
    echo 1
  else
    echo "0 no mise data dir"
  fi
}
clean_misetools() {
  command -v mise >/dev/null 2>&1 || return 1
  # --yes: without a TTY mise refuses to prune ("nobody to ask") and exits
  # silently, pruning nothing — which used to report ok with zero freed.
  mise prune --tools --yes >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# Applications — AyuGram (Telegram) media cache
# ---------------------------------------------------------------------------
# Telegram re-downloads previews and images from the cloud when next
# viewed, so media_cache and cache under tdata/user_data are only disk
# fat. Login state (tdata root files and the databases) is never touched.
_ayugram_user_data() { echo "$TIDY_HOME/.local/share/AyuGramDesktop/tdata/user_data"; }
# Bracket trick keeps this grep from matching its own command line.
_ayugram_running() { pgrep -f 'Ayu[G]ram' >/dev/null 2>&1; }
_ayugram_caches() {
  for d in "$(_ayugram_user_data)/media_cache" "$(_ayugram_user_data)/cache"; do
    [ -d "$d" ] && echo "$d"
  done
}
measure_ayugram() { _ayugram_caches | sum_bytes_lines; }
files_ayugram() {
  local n=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$((n + $(find "$d" -type f 2>/dev/null | _count_lines)))
  done < <(_ayugram_caches)
  echo "$n"
}
avail_ayugram() {
  if [ -d "$(_ayugram_user_data)" ]; then
    if _ayugram_running; then echo "0 AyuGram is open"; return; fi
    echo 1
  else
    echo "0 AyuGram not installed"
  fi
}
clean_ayugram() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    _clear_dir "$d"
  done < <(_ayugram_caches)
}

# ---------------------------------------------------------------------------
# Applications — Omarchy widget caches
# ---------------------------------------------------------------------------
# Omarchy's widgets keep thumbnail caches (wallpaper image selector, theme
# selector) regenerated on demand. The keybinding record and agent-usage
# files in the same directory are state, not cache, and stay.
measure_omarchycache() {
  _glob_bytes "$TIDY_HOME/.cache/omarchy/image-selector" "$TIDY_HOME/.cache/omarchy/theme-selector"
}
files_omarchycache() {
  local n=0 d
  for d in "$TIDY_HOME/.cache/omarchy/image-selector" "$TIDY_HOME/.cache/omarchy/theme-selector"; do
    [ -d "$d" ] && n=$((n + $(find "$d" -type f 2>/dev/null | _count_lines)))
  done
  echo "$n"
}
avail_omarchycache() {
  if [ -d "$TIDY_HOME/.cache/omarchy" ]; then echo 1; else echo "0 no omarchy cache"; fi
}
clean_omarchycache() {
  _tidy_wipe "$TIDY_HOME/.cache/omarchy/image-selector" "$TIDY_HOME/.cache/omarchy/theme-selector"
  _clear_dir "$TIDY_HOME/.cache/omarchy/image-selector" "$TIDY_HOME/.cache/omarchy/theme-selector"
}

# ---------------------------------------------------------------------------
# Applications — chromium-headless leftovers
# ---------------------------------------------------------------------------
# Chromium's headless mode dumps temp scoped_dir* profiles into
# ~/.cache/chromium-headless and does not always reap them. The whole dir
# is scratch space; skipped while a headless instance is running.
_chromheadless_root() { echo "$TIDY_HOME/.cache/chromium-headless"; }
_chromheadless_running() { pgrep -f 'chrom[i]um-headless|headl[e]ss_shell' >/dev/null 2>&1; }
measure_chromheadless() { _path_bytes "$(_chromheadless_root)"; }
files_chromheadless() {
  find "$(_chromheadless_root)" -mindepth 1 -maxdepth 1 2>/dev/null | _count_lines
}
avail_chromheadless() {
  if [ -d "$(_chromheadless_root)" ]; then
    if _chromheadless_running; then echo "0 a headless browser is running"; return; fi
    echo 1
  else
    echo "0 no chromium-headless cache"
  fi
}
clean_chromheadless() {
  _tidy_wipe "$(_chromheadless_root)"
  _clear_dir "$(_chromheadless_root)"
}

# ---------------------------------------------------------------------------
# Applications — mise tool cache
# ---------------------------------------------------------------------------
# Downloads and package stores under ~/.cache/mise are disposable: mise
# re-downloads whatever the next install actually needs, and installed
# toolchains in ~/.local/share/mise are never touched. Same on-demand
# philosophy as the AUR build cache.
measure_mise() { _path_bytes "$TIDY_HOME/.cache/mise"; }
files_mise() {
  find "$TIDY_HOME/.cache/mise" -mindepth 1 -maxdepth 1 2>/dev/null | _count_lines
}
avail_mise() {
  if [ -d "$TIDY_HOME/.cache/mise" ]; then echo 1; else echo "0 no mise cache"; fi
}
clean_mise() {
  _tidy_wipe "$TIDY_HOME/.cache/mise"
  _clear_dir "$TIDY_HOME/.cache/mise"
}

# ---------------------------------------------------------------------------
# Applications — npm cache
# ---------------------------------------------------------------------------
_npm_caches() {
  for d in "$TIDY_HOME/.npm/_cacache" "$TIDY_HOME/.npm/_npx"; do
    [ -d "$d" ] && echo "$d"
  done
}
measure_npm() { _npm_caches | sum_bytes_lines; }
files_npm() {
  local n=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$((n + $(find "$d" -type f 2>/dev/null | _count_lines)))
  done < <(_npm_caches)
  echo "$n"
}
avail_npm() {
  if [ -d "$TIDY_HOME/.npm" ]; then echo 1; else echo "0 no npm cache"; fi
}
clean_npm() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    _clear_dir "$d"
  done < <(_npm_caches)
}

# ---------------------------------------------------------------------------
# Applications — JetBrains / Android Studio IDE caches
# ---------------------------------------------------------------------------
# IDE indexes and caches live under ~/.cache/Google/AndroidStudio* and
# ~/.cache/JetBrains; settings live elsewhere and are never touched. A
# deleted index is rebuilt on next open, so this is skipped while an IDE
# is actually running.
_ide_cache_dirs() {
  for d in "$TIDY_HOME"/.cache/Google/AndroidStudio* "$TIDY_HOME"/.cache/JetBrains; do
    [ -d "$d" ] && echo "$d"
  done
}
# Bracket-trick pattern so the grep cannot match this script's own command
# line if it is ever pgrep'd itself.
_ide_running() { pgrep -f 'Android[S]tudio|[a]ndroid-studio' >/dev/null 2>&1; }
measure_androidstudio() { _ide_cache_dirs | sum_bytes_lines; }
files_androidstudio() {
  local n=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$((n + $(find "$d" -type f 2>/dev/null | _count_lines)))
  done < <(_ide_cache_dirs)
  echo "$n"
}
avail_androidstudio() {
  if [ -z "$(_ide_cache_dirs)" ]; then echo "0 no IDE cache directories"; return; fi
  if _ide_running; then echo "0 Android Studio is open"; return; fi
  echo 1
}
clean_androidstudio() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    _tidy_wipe "$d"
    _clear_dir "$d"
  done < <(_ide_cache_dirs)
}

# ---------------------------------------------------------------------------
# Applications — Docker
# ---------------------------------------------------------------------------
measure_docker() {
  command -v docker >/dev/null 2>&1 || { echo 0; return; }
  local out total=0 type s
  out="$(docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)" || { echo 0; return; }
  while IFS=$'\t' read -r type s; do
    [ -n "$s" ] || continue
    # `prune` leaves volumes alone unless asked, so counting them here would
    # promise space the cleanup never actually returns.
    if [ "$TIDY_DOCKER_VOLUMES" != 1 ]; then
      case "$type" in *Volume*) continue ;; esac
    fi
    total=$((total + $(_hb "${s%% *}")))
  done <<<"$out"
  echo "$total"
}
files_docker() {
  command -v docker >/dev/null 2>&1 || { echo 0; return; }
  local n=0 c
  c="$(docker ps -aq --filter status=exited 2>/dev/null | _count_lines)"
  n=$((n + c))
  c="$(docker images -qf dangling=true 2>/dev/null | _count_lines)"
  n=$((n + c))
  echo "$n"
}
avail_docker() {
  if ! command -v docker >/dev/null 2>&1; then echo "0 Docker not installed"; return; fi
  if docker info >/dev/null 2>&1; then echo 1; return; fi
  echo "0 Docker daemon not running"
}
clean_docker() {
  docker info >/dev/null 2>&1 || return 1
  if [ "$TIDY_DOCKER_VOLUMES" = 1 ]; then
    docker system prune -f --volumes >/dev/null 2>&1
  else
    docker system prune -f >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------------------
# Applications — Flatpak
# ---------------------------------------------------------------------------
# The measurement asks flatpak itself what is unused, so the number the panel
# shows is the same set the cleanup removes. Counting runtimes by hand would
# have to reimplement flatpak's dependency graph, and getting that wrong means
# promising space that never comes back.

_flatpak_unused_refs() {
  command -v flatpak >/dev/null 2>&1 || return 0
  flatpak uninstall --unused --user </dev/null 2>/dev/null | awk '
    $1 !~ /^[0-9]+\.$/ { next }
    {
      ref = ""; branch = ""
      for (i = 2; i <= NF; i++) {
        if ($i == "r" || $i == "s" || $i == "u") continue
        if (ref == "" && $i ~ /\./) { ref = $i; continue }
        if (ref != "" && branch == "") { branch = $i }
      }
      if (ref != "") print (branch == "" ? ref : ref "/" branch)
    }' | sort -u
}

_flatpak_size_of() {
  local app="$1" rref rsize
  while IFS=$'\t' read -r rref rsize; do
    case "$rref" in
      "$app"/*)
        _hb "$rsize"
        return
        ;;
    esac
  done
  echo 0
}

measure_flatpak() {
  local refs r app sizes total=0 b
  refs="$(_flatpak_unused_refs)"
  [ -n "$refs" ] || { echo 0; return; }
  sizes="$(flatpak list --user --runtime --columns=ref,size 2>/dev/null)"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    app="${r%%/*}"
    b="$(printf '%s\n' "$sizes" | _flatpak_size_of "$app")"
    total=$((total + ${b:-0}))
  done <<<"$refs"
  echo "$total"
}
files_flatpak() { _flatpak_unused_refs | _count_lines; }
avail_flatpak() {
  if command -v flatpak >/dev/null 2>&1; then echo 1; else echo "0 Flatpak not installed"; fi
}
clean_flatpak() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak uninstall --unused --user -y >/dev/null 2>&1
  return 0
}
