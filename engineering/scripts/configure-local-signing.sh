#!/bin/zsh
# Keep the same Apple ID team and bundle prefix across all weekly reinstalls.
set -euo pipefail
cd "${0:A:h:h:h}"
exec python3 engineering/scripts/lib/local_signing.py "$@"
