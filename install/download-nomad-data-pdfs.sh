#!/usr/bin/env bash
# Download all documents listed in install/nomad-data-pdf-urls.txt into NOMAD-DATA.
#
# Usage:
#   ./install/download-nomad-data-pdfs.sh [TARGET_DIR]      download / refresh
#   ./install/download-nomad-data-pdfs.sh --verify [TARGET] only check what is on disk
#
#   TARGET_DIR defaults to $NOMAD_DATA_PATH or ./NOMAD-DATA
#
# Why this script verifies instead of just fetching: several of the source
# agencies answer a dead link with HTTP 200 and an HTML error page. A plain
# `wget -O name.pdf` then writes that HTML under a .pdf name, and a failed
# fetch still leaves a 0-byte file behind. Both land in NOMAD's knowledge base
# as unreadable "documents" and fail at embed time, long after the download
# looked successful. Every file is therefore written to a temp path first and
# only moved into place once its magic bytes match the expected type.
#
# Exits non-zero if anything failed, so a caller can actually notice.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="${SCRIPT_DIR}/nomad-data-pdf-urls.txt"

VERIFY_ONLY=0
if [[ "${1:-}" == "--verify" ]]; then VERIFY_ONLY=1; shift; fi
TARGET="${1:-${NOMAD_DATA_PATH:-$REPO_ROOT/NOMAD-DATA}}"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 1
fi
command -v curl >/dev/null || { echo "curl required" >&2; exit 1; }

# Magic-byte check. Returns 0 when the file looks like the type its name claims.
looks_valid() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  local lower
  lower="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.pdf) head -c 5 "$f" | grep -q '%PDF-' ;;
    *.zip) head -c 2 "$f" | grep -q 'PK' ;;
    *)     return 0 ;;   # unknown extension: non-empty is all we can assert
  esac
}

ok=0; failed=0; skipped=0
declare -a FAILURES=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  # Format: SUBDIR<TAB>URL[<TAB>DATEINAME]
  # Die dritte Spalte ist optional und ueberschreibt den aus der URL
  # abgeleiteten Namen - noetig bei Quellen wie IRIS, deren URL auf
  # "/content" endet und sonst eine Datei namens "content" ergibt.
  # Alte Zeilen trennen teils mit Leerzeichen statt Tab -> erst normalisieren.
  case "$line" in
    *"$(printf '\t')"*) : ;;
    *) line="$(printf '%s' "$line" | sed 's/[[:space:]][[:space:]]*/\t/')" ;;
  esac
  subdir="$(printf '%s' "$line" | cut -f1)"
  url="$(printf '%s' "$line" | cut -f2)"
  want_name="$(printf '%s' "$line" | cut -f3)"
  [[ -z "$url" || "$url" == "$subdir" ]] && continue

  dir="$TARGET/$subdir"
  if [[ -n "$want_name" && "$want_name" != "$url" ]]; then
    filename="$want_name"
  else
    raw_name="$(basename "${url%%\?*}")"
    filename="$(printf '%s' "$raw_name" | sed 's/%20/_/g; s/%2B/+/g')"
  fi
  if [[ -z "$filename" ]]; then
    hash="$( { printf '%s' "$url" | sha256sum 2>/dev/null || printf '%s' "$url" | shasum -a 256 2>/dev/null; } | cut -c1-12)"
    filename="doc_${hash}.pdf"
  fi
  dest="$dir/$filename"

  if (( VERIFY_ONLY )); then
    case "$dest" in
      *.pdf|*.PDF|*.zip|*.ZIP|*.txt|*.md|*.epub|*.docx) : ;;
      *) [[ -e "${dest}.pdf" ]] && dest="${dest}.pdf" ;;
    esac
    if [[ ! -e "$dest" ]]; then
      echo "MISSING  $subdir/$filename"; FAILURES+=("MISSING $subdir/$filename"); ((failed++))
    elif looks_valid "$dest"; then
      ((ok++))
    else
      echo "CORRUPT  $subdir/$filename ($(stat -c%s "$dest" 2>/dev/null || echo 0) bytes)"
      FAILURES+=("CORRUPT $subdir/$filename"); ((failed++))
    fi
    continue
  fi

  # Already present and sane -> leave it alone.
  case "$dest" in
    *.pdf|*.PDF|*.zip|*.ZIP|*.txt|*.md|*.epub|*.docx) : ;;
    *) [[ -e "${dest}.pdf" ]] && dest="${dest}.pdf" ;;
  esac
  if [[ -e "$dest" ]] && looks_valid "$dest"; then
    ((skipped++)); continue
  fi

  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/.dl.XXXXXX")"
  code="$(curl -sSL --http1.1 -A "$UA" --retry 2 --retry-delay 2 --max-time 180 \
            -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)"

  if [[ "$code" != "200" ]]; then
    echo "HTTP $code  $subdir/$filename  <- $url"
    FAILURES+=("HTTP $code $subdir/$filename"); rm -f "$tmp"; ((failed++)); continue
  fi
  if ! looks_valid "$tmp"; then
    # The classic case: 200 OK with an HTML error page under a .pdf name.
    echo "NOT-A-PDF  $subdir/$filename  <- $url  ($(head -c 200 "$tmp" | tr -d '\0' | head -1 | cut -c1-60))"
    FAILURES+=("NOT-A-PDF $subdir/$filename"); rm -f "$tmp"; ((failed++)); continue
  fi

  # Manche Quellen liefern das PDF unter einer URL ohne Dateiendung
  # (z. B. IRIS: .../bitstreams/<uuid>/content). Ohne ".pdf" haelt NOMAD die
  # Datei fuer einen unbekannten Typ und laesst sie beim Einbetten liegen —
  # sie waere heruntergeladen, aber unsichtbar fuer die Wissensdatenbank.
  case "$dest" in
    *.pdf|*.PDF|*.zip|*.ZIP|*.txt|*.md|*.epub|*.docx) : ;;
    *) if head -c 5 "$tmp" | grep -q '%PDF-'; then dest="${dest}.pdf"; fi ;;
  esac

  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  ((ok++))
done < "$MANIFEST"

echo
if (( VERIFY_ONLY )); then
  echo "Verify: $ok in Ordnung, $failed fehlerhaft."
else
  echo "Download: $ok neu/erneuert, $skipped bereits vorhanden, $failed fehlgeschlagen."
fi
if (( failed )); then
  echo
  echo "Fehlgeschlagen:"
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
