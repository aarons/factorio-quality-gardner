#!/bin/bash

# Runs all validations for the mod (currently luacheck).
# Single source of truth for checks; package.sh runs this before packaging.

set -e

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if luacheck . --quiet --exclude-files reference/; then
    echo "✅ Luacheck passed"
else
    echo "❌ Luacheck failed"
    exit 1
fi
