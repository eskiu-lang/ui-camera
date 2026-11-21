#!/bin/sh
# CI on a desktop: the example built with the ui tool for a native desktop host, which
# compiles and links the package's native/macos, native/linux or native/windows code
# (windows from Linux too, with CXX naming a MinGW-w64 compiler).
# tools/ci_desktop.sh linux|windows|macos
set -e
host="$1"
example=snap
case "$host" in
    linux|windows|macos) ;;
    *) echo "usage: tools/ci_desktop.sh linux|windows|macos"; exit 2 ;;
esac
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/build"
cd "$root/examples/$example"
eskiuc fetch
ui_src="${ESKIU_HOME:-$HOME/.eskiu}/pkgs/ui/$(awk -F'\t' '$1 == "ui" { print $5 }' eskiu.lock)"
tool="$root/build/ui"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tool="$tool.exe" ;; esac
[ -x "$tool" ] || eskiuc "$ui_src/tools/ui/main.esk" -o "$tool"
"$tool" build "$host"
echo "PASS desktop $host"
