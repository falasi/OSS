#!/usr/bin/env bash
#
# pull-apk.sh — search for an installed Android package by keyword,
# pull all its split APKs from a connected device/emulator, and
# merge them into a single APK ready for static analysis.
#
# Usage:  ./pull-apk.sh <search_term>
# Example: ./pull-apk.sh lyft
#          ./pull-apk.sh driver
#
# Requires: adb, java, curl. Auto-downloads APKEditor.jar on first run.

set -euo pipefail

# ---------- config ----------
APKEDITOR_VERSION="1.4.3"
APKEDITOR_URL="https://github.com/REAndroid/APKEditor/releases/download/V${APKEDITOR_VERSION}/APKEditor-${APKEDITOR_VERSION}.jar"
APKEDITOR_JAR="${HOME}/.local/share/apkeditor/APKEditor-${APKEDITOR_VERSION}.jar"
OUTPUT_ROOT="./pulled_apks"

# ---------- helpers ----------
red()   { printf "\033[0;31m%s\033[0m\n" "$*"; }
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[0;34m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[0;33m%s\033[0m\n" "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# ---------- preflight ----------
[ $# -ge 1 ] || die "usage: $0 <search_term>"
SEARCH="$1"

command -v adb  >/dev/null 2>&1 || die "adb not found in PATH"
command -v java >/dev/null 2>&1 || die "java not found in PATH (needed for APKEditor)"
command -v curl >/dev/null 2>&1 || die "curl not found in PATH"

adb get-state >/dev/null 2>&1 || die "no device/emulator connected (check 'adb devices')"

# ---------- fetch APKEditor if missing ----------
if [ ! -f "$APKEDITOR_JAR" ]; then
  blue "[*] APKEditor not found, downloading v${APKEDITOR_VERSION}..."
  mkdir -p "$(dirname "$APKEDITOR_JAR")"
  curl -L --fail -o "$APKEDITOR_JAR" "$APKEDITOR_URL" \
    || die "failed to download APKEditor from $APKEDITOR_URL"
  green "[+] APKEditor saved to $APKEDITOR_JAR"
fi

# ---------- find matching package ----------
blue "[*] Searching installed packages for: $SEARCH"

# Grep both third-party and system packages; let user filter later if needed
mapfile -t MATCHES < <(adb shell pm list packages 2>/dev/null \
  | sed 's/^package://' | tr -d '\r' \
  | grep -i "$SEARCH" || true)

if [ ${#MATCHES[@]} -eq 0 ]; then
  die "no installed package matches '$SEARCH'"
fi

if [ ${#MATCHES[@]} -eq 1 ]; then
  PKG="${MATCHES[0]}"
  green "[+] Match: $PKG"
else
  yellow "[?] Multiple matches found:"
  for i in "${!MATCHES[@]}"; do
    printf "    [%d] %s\n" "$((i+1))" "${MATCHES[$i]}"
  done
  printf "Select a package [1-%d]: " "${#MATCHES[@]}"
  read -r choice
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MATCHES[@]}" ] \
    || die "invalid selection"
  PKG="${MATCHES[$((choice-1))]}"
  green "[+] Selected: $PKG"
fi

# ---------- resolve APK paths ----------
blue "[*] Resolving APK paths for $PKG"
mapfile -t APK_PATHS < <(adb shell pm path "$PKG" 2>/dev/null \
  | sed 's/^package://' | tr -d '\r' | grep -E '\.apk$' || true)

[ ${#APK_PATHS[@]} -gt 0 ] || die "no APK paths returned by 'pm path $PKG'"

green "[+] Found ${#APK_PATHS[@]} APK file(s):"
for p in "${APK_PATHS[@]}"; do
  printf "    %s\n" "$p"
done

# ---------- pull APKs ----------
WORK_DIR="${OUTPUT_ROOT}/${PKG}"
SPLITS_DIR="${WORK_DIR}/splits"
mkdir -p "$SPLITS_DIR"

blue "[*] Pulling APK files into $SPLITS_DIR"
for p in "${APK_PATHS[@]}"; do
  name="$(basename "$p")"
  printf "    pulling %s..." "$name"
  if adb pull "$p" "$SPLITS_DIR/$name" >/dev/null 2>&1; then
    printf " \033[0;32mok\033[0m\n"
  else
    printf " \033[0;33mfailed, retrying via su...\033[0m\n"
    # Fallback: stage via /sdcard using su (works on Magisk-rooted AVDs)
    adb shell "su -c 'cp \"$p\" /sdcard/Download/$name && chmod 644 /sdcard/Download/$name'" \
      || die "su fallback failed for $p (is the device rooted?)"
    adb pull "/sdcard/Download/$name" "$SPLITS_DIR/$name" >/dev/null \
      || die "pull from /sdcard failed for $name"
    adb shell "rm /sdcard/Download/$name" >/dev/null 2>&1 || true
  fi
done

# ---------- merge into one APK ----------
MERGED_APK="${WORK_DIR}/${PKG}_merged.apk"

if [ ${#APK_PATHS[@]} -eq 1 ]; then
  # Not a split APK — just copy and rename
  cp "$SPLITS_DIR"/*.apk "$MERGED_APK"
  green "[+] Single APK (no splits), copied to $MERGED_APK"
else
  blue "[*] Merging ${#APK_PATHS[@]} splits into one APK via APKEditor"
  java -jar "$APKEDITOR_JAR" m \
    -i "$SPLITS_DIR" \
    -o "$MERGED_APK" \
    -f 2>&1 | sed 's/^/    /' \
    || die "APKEditor merge failed"
  green "[+] Merged APK: $MERGED_APK"
fi

# ---------- summary ----------
echo
green "================ DONE ================"
echo "  package : $PKG"
echo "  splits  : $SPLITS_DIR"
echo "  merged  : $MERGED_APK"
echo
echo "Next steps for static analysis:"
echo "  jadx -d ${WORK_DIR}/decompiled $MERGED_APK"
echo "  # or feed $MERGED_APK to MobSF / Ghidra / your tool of choice"
