#!/usr/bin/env bash
# diskhound - sniff out what's eating your disk, then clear it one item at a time.
# Works on macOS and Linux. MIT licensed.
set -u

TOP=20
MIN_MB=100
DRY=0
ROOT="$HOME"
TAB="$(printf '\t')"

usage() {
  cat <<EOF
Usage: diskhound.sh [options] [directory]

  --top N       how many items to list (default 20)
  --min-mb N    minimum size for large-file detection (default 100)
  --dry-run     walk through everything, but never delete
  -h, --help    show this help

Scans your home directory by default.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --top)    TOP="${2:?--top needs a number}"; shift ;;
    --min-mb) MIN_MB="${2:?--min-mb needs a number}"; shift ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)  ROOT="${1%/}" ;;
  esac
  shift
done

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "Unsupported OS: $OS (on Windows, use diskhound.ps1)"; exit 1 ;;
esac

[ -d "$ROOT" ] || { echo "Not a directory: $ROOT" >&2; exit 1; }

# ---------- colours (only when writing to a terminal) ----------
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; D=""; R=""; G=""; Y=""; C=""; N=""
fi

human() {
  awk -v k="$1" 'BEGIN{ if (k>=1048576) printf "%.1f GB", k/1048576; else if (k>=1024) printf "%.0f MB", k/1024; else printf "%d KB", k }'
}

have() { command -v "$1" >/dev/null 2>&1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CAND="$TMP/cand"
: > "$CAND"

echo "${C}${B}"
echo "  diskhound  -  find what's eating your disk"
echo "${N}${D}  scanning: $ROOT   mode: $([ "$DRY" -eq 1 ] && echo dry-run || echo live)${N}"

# ---------- 1. disk overview ----------
echo
echo "${B}1. Disk overview${N}"
df -kP "$ROOT" | awk 'NR==2{ printf "   Total %.0f GB   Used %.0f GB (%s)   Free %.0f GB\n", $2/1048576, $3/1048576, $5, $4/1048576 }'

# ---------- 2. where the space lives ----------
echo
echo "${B}2. Biggest folders in $ROOT${N}  ${D}(this can take a minute)${N}"
find "$ROOT" -mindepth 1 -maxdepth 1 -exec du -sk {} + 2>/dev/null | sort -rn | head -10 | awk -F'\t' '
  function h(k){ if(k>=1048576) return sprintf("%.1f GB",k/1048576); if(k>=1024) return sprintf("%.0f MB",k/1024); return sprintf("%d KB",k) }
  NR==1{ max=$1 }
  { n=int(24*$1/max); bar=""; for(i=0;i<n;i++) bar=bar "#"; name=$2; sub(".*/","",name);
    printf "   %-28s %9s  %s\n", substr(name,1,28), h($1), bar }'

# ---------- 3. hunt for the top offenders ----------
echo
echo "${B}3. Hunting for the top $TOP space hogs...${N}"

add() { # add <path> <label>
  [ -e "$1" ] || return 0
  local kb
  kb="$(du -sk "$1" 2>/dev/null | cut -f1)"
  if [ -n "$kb" ] && [ "$kb" -ge 10240 ]; then
    printf '%s\t%s\t%s\n' "$kb" "$1" "$2" >> "$CAND"
  fi
  return 0
}

# Known developer / system caches (only when scanning your home dir)
if [ "$ROOT" = "$HOME" ]; then
  add "$HOME/.npm/_cacache"                         "npm cache"
  add "$HOME/.cache"                                "user cache"
  add "$HOME/.gradle/caches"                        "Gradle cache"
  add "$HOME/.m2/repository"                        "Maven repository"
  add "$HOME/.android/cache"                        "Android cache"
  for d in "$HOME"/.android/avd/*/snapshots; do
    add "$d" "Android emulator snapshots"
  done
  if [ "$OS" = "Darwin" ]; then
    add "$HOME/Library/Caches"                                  "App caches"
    add "$HOME/Library/Logs"                                    "Logs"
    add "$HOME/Library/Developer/Xcode/DerivedData"             "Xcode DerivedData"
    add "$HOME/Library/Developer/Xcode/iOS DeviceSupport"       "Xcode device support"
    add "$HOME/.Trash"                                          "Trash"
  else
    add "$HOME/.local/share/Trash"                              "Trash"
  fi
fi

# Every node_modules folder
find "$ROOT" -type d -name node_modules -prune -print 2>/dev/null |
  while IFS= read -r p; do add "$p" "node_modules"; done

# Large individual files
find "$ROOT" -type f -size +"${MIN_MB}M" -print 2>/dev/null | grep -v '/node_modules/' |
  while IFS= read -r p; do add "$p" "large file"; done

sort -t "$TAB" -k2,2 -u "$CAND" | sort -t "$TAB" -k1,1 -rn | head -n "$TOP" > "$TMP/top"

if [ ! -s "$TMP/top" ]; then
  echo "   Nothing big found. Your disk is looking healthy."
  exit 0
fi

echo
echo "${B}   Top space hogs${N}"
awk -F'\t' -v home="$HOME" '
  function h(k){ if(k>=1048576) return sprintf("%.1f GB",k/1048576); if(k>=1024) return sprintf("%.0f MB",k/1024); return sprintf("%d KB",k) }
  { p=$2; if (index(p,home)==1) p="~" substr(p,length(home)+1); total+=$1;
    printf "   %2d. %9s  %-26s %s\n", NR, h($1), $3, p }
  END { printf "\n   Potentially reclaimable: %s\n", h(total) }' "$TMP/top"

# ---------- 4. clear them one by one ----------
is_safe() { # only ever delete things strictly inside the scanned directory
  case "$1" in
    "$ROOT"/?*) return 0 ;;
    *) return 1 ;;
  esac
}

reveal() {
  if [ "$OS" = "Darwin" ]; then
    open -R "$1"
  else
    xdg-open "$(dirname "$1")" >/dev/null 2>&1 || echo "   (no file manager found) $1"
  fi
}

echo
echo "${B}4. Clean up one by one${N}  ${D}(nothing is deleted without your confirmation)${N}"
FREED=0
QUIT=0
TOTAL="$(wc -l < "$TMP/top" | tr -d ' ')"
IDX=0
exec 3< "$TMP/top"
while IFS="$TAB" read -r kb path label <&3; do
  IDX=$((IDX + 1))
  [ -e "$path" ] || continue
  echo
  echo "${B}[$IDX/$TOTAL]${N} $path"
  echo "   $(human "$kb")  ${D}($label)${N}"
  case "$path" in
    *.vmdk|*.vdi|*.qcow2|*.vhdx|*.vmwarevm*)
      echo "   ${Y}Warning: looks like a virtual machine disk. Deleting it destroys that VM.${N}" ;;
  esac
  while :; do
    printf "   [d]elete  [o]pen location  [s]kip  [q]uit > "
    read -r ans </dev/tty || ans=q
    case "$ans" in
      d|D)
        if ! is_safe "$path"; then
          echo "   ${R}Refused: path is outside the scan root.${N}"; continue
        fi
        printf "   ${R}Permanently delete this?${N} [y/N] "
        read -r yn </dev/tty || yn=n
        case "$yn" in
          y|Y)
            if [ "$DRY" -eq 1 ]; then
              echo "   ${Y}(dry run) would delete, freeing $(human "$kb")${N}"
            else
              rm -rf -- "$path" 2>/dev/null
              if [ -e "$path" ]; then
                echo "   ${R}Could not fully delete (permissions or in use).${N}"
              else
                FREED=$((FREED + kb))
                echo "   ${G}Deleted. Freed $(human "$kb").${N}"
              fi
            fi
            break ;;
          *) echo "   Kept." ;;
        esac ;;
      o|O) reveal "$path" ;;
      s|S|"") echo "   Skipped."; break ;;
      q|Q) QUIT=1; break ;;
      *) echo "   Pick d, o, s or q." ;;
    esac
  done
  [ "$QUIT" -eq 1 ] && break
done
exec 3<&-

# ---------- 5. optional system-level cleanups ----------
ask_run() { # ask_run <description> <command...>
  local desc="$1"; shift
  echo
  echo "   $desc"
  echo "   ${D}\$ $*${N}"
  printf "   Run it? [y/N] "
  read -r yn </dev/tty || yn=n
  case "$yn" in
    y|Y)
      if [ "$DRY" -eq 1 ]; then echo "   ${Y}(dry run) skipped${N}"; else "$@"; fi ;;
  esac
}

echo
echo "${B}5. Optional package and system cleanups${N}"
if have docker && docker info >/dev/null 2>&1; then
  docker system df
  ask_run "Remove unused Docker images, containers and build cache" docker system prune -a
fi
have npm && ask_run "Clear the npm cache" npm cache clean --force
if [ "$OS" = "Darwin" ]; then
  have brew && ask_run "Clean old Homebrew downloads and versions" brew cleanup -s
else
  have apt-get && ask_run "Remove unused apt packages" sudo apt-get autoremove -y
  have apt-get && ask_run "Clear the apt package cache" sudo apt-get clean
  have dnf && ask_run "Clear the dnf cache" sudo dnf clean all
  have journalctl && ask_run "Trim system logs to 200 MB" sudo journalctl --vacuum-size=200M
fi

echo
echo "${G}${B}Done. Freed about $(human "$FREED") in this run.${N}"
df -kP "$ROOT" | awk 'NR==2{ printf "   Free space now: %.0f GB\n", $4/1048576 }'
