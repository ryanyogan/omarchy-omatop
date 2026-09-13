#!/usr/bin/env bash
set -euo pipefail
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
probe_dir=$(mktemp -d /tmp/omatop-dot-test.XXXXXXXX)
trap 'rm -rf -- "$probe_dir"' EXIT
ln -s "$plugin_dir/ui" "$probe_dir/ui"
ln -s "${OMARCHY_PATH:-/usr/share/omarchy}/shell/Commons" "$probe_dir/Commons"
cp "$plugin_dir/tests/dot-matrix.qml" "$probe_dir/shell.qml"
if ! timeout 10 quickshell -p "$probe_dir/shell.qml" >"$probe_dir/result" 2>&1; then
  cat "$probe_dir/result"
  exit 1
fi
if rg -q 'FAIL:|ERROR' "$probe_dir/result" || ! rg -q 'PASS:' "$probe_dir/result"; then
  cat "$probe_dir/result"
  exit 1
fi
rg 'PASS:' "$probe_dir/result"
