#!/usr/bin/env bash
set -euo pipefail
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
probe_dir=$(mktemp -d /tmp/omatop-update-test.XXXXXXXX)
trap 'rm -rf -- "$probe_dir"' EXIT
mkdir -p "$probe_dir/sampler/target/release" "$probe_dir/bin"
cp "$plugin_dir/Service.qml" "$plugin_dir/Model.js" "$probe_dir/"
cp "$plugin_dir/tests/sampler-update.qml" "$probe_dir/shell.qml"
ln -s "${OMARCHY_PATH:-/usr/share/omarchy}/shell/Commons" "$probe_dir/Commons"
cat > "$probe_dir/sampler/target/release/omatop-sampler" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, time
version = pathlib.Path(__file__).parents[2] / 'version'
tick = {'v': 1, 'vitals': {'cpu': {'total': os.getpid()}}}
if version.exists():
    tick['samplerVersion'] = version.read_text().strip()
while True:
    print(json.dumps(tick), flush=True)
    time.sleep(0.05)
PY
cat > "$probe_dir/bin/cargo" <<'PY'
#!/usr/bin/env python3
import pathlib, sys, time
sampler = pathlib.Path(sys.argv[-1]).parent
attempts = sampler / 'attempts'
n = int(attempts.read_text()) + 1 if attempts.exists() else 1
attempts.write_text(str(n))
time.sleep(0.15)
if n == 1:
    print('intentional test failure', file=sys.stderr)
    sys.exit(1)
(sampler / 'version').write_text('1.2.2')
PY
chmod +x "$probe_dir/bin/cargo" "$probe_dir/sampler/target/release/omatop-sampler"
if ! PATH="$probe_dir/bin:$PATH" timeout 10 quickshell -p "$probe_dir/shell.qml" >"$probe_dir/result" 2>&1; then
  cat "$probe_dir/result"
  exit 1
fi
if rg -q 'FAIL:|ERROR' "$probe_dir/result" || ! rg -q 'PASS:' "$probe_dir/result"; then
  cat "$probe_dir/result"
  exit 1
fi
[[ $(cat "$probe_dir/sampler/attempts") == 2 ]]
rg 'PASS:' "$probe_dir/result"
