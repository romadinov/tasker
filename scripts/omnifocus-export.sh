#!/bin/bash
# Exports the OmniFocus database to JSON (same script the Mac app runs).
# Usage: scripts/omnifocus-export.sh out.json
set -euo pipefail
out="${1:-omnifocus-export.json}"
tmp=$(mktemp -d)
python3 - "$tmp/export.js" <<'PY'
import sys, pathlib
src = pathlib.Path(__file__).parent if False else None
s = open("Packages/TaskerCore/Sources/TaskerCore/OmniFocusImport.swift").read()
open(sys.argv[1], "w").write(s.split('#"""')[1].split('"""#')[0])
PY
osascript <<OSA > "$out"
set js to read POSIX file "$tmp/export.js" as «class utf8»
with timeout of 900 seconds
tell application id "com.omnigroup.OmniFocus4" to return (evaluate javascript js)
end timeout
OSA
rm -rf "$tmp"
echo "Wrote $out"
