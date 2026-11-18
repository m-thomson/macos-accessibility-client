#!/bin/bash
set -euo pipefail
repository_root="$(cd "$(dirname "$0")" && pwd -P)"
exec /usr/bin/python3 -B "$repository_root/tools/dev.py" "$@"
