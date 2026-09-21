#!/bin/sh
# eng/verify.sh - Unix thin entry point. All stages and parameters live in eng/verify.core.sh.
set -e
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$SCRIPT_DIR/verify.core.sh" "$@"
