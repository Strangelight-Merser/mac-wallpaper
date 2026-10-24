#!/bin/bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <version> [zip-path]" >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$1"
zip="${2:-$root/dist/MacWallpaper-$version.zip}"
python3 - "$version" "$zip" "$root/packaging/homebrew/macwallpaper.rb" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

version, archive, cask = sys.argv[1:]
if not re.fullmatch(r"[0-9][0-9A-Za-z.+-]*", version):
    sys.exit("Expected a version such as 1.2.3 (without the v prefix)")
digest = hashlib.sha256()
with open(archive, "rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
path = Path(cask)
text = path.read_text()
for key, value in (("version", version), ("sha256", digest.hexdigest())):
    text, count = re.subn(rf'^  {key} "[^"]*"$', f'  {key} "{value}"', text, flags=re.MULTILINE)
    if count != 1:
        sys.exit(f"Expected exactly one {key} stanza")
path.write_text(text)
print(f"Updated {path}: {version}, {digest.hexdigest()}")
PY
