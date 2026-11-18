#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if ! command -v python3 >/dev/null 2>&1; then
    echo "Install Python 3 first (Mac: python.org; Ubuntu: sudo apt install python3)." >&2
    exit 1
fi
exec python3 setup.py  "$@"
