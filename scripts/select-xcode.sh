#!/bin/bash
set -euo pipefail
developer=/Applications/Xcode_26.3.app/Contents/Developer
if [[ ! -d "$developer" ]]; then
  echo "::error::Xcode 26.3 is required but is unavailable on this runner."
  exit 1
fi
sudo xcode-select --switch "$developer"
xcodebuild -version
