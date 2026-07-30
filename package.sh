#!/bin/bash

# This script packages the Factorio mod for release.
# It reads the mod name and version from info.json and creates a zip file
# named quality-gardener_<version>.zip under builds/, excluding the .git
# directory. This is the 2.0 release line: unlike the 2.1 branch, the zip is
# not copied into the local Factorio mods folder (a 2.1 install can't load it).

set -e

# Parse command line arguments
FORCE_PACKAGE=false
for arg in "$@"; do
    case $arg in
        --force)
            FORCE_PACKAGE=true
            shift
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--force]"
            echo "  --force    Skip validation and package anyway"
            exit 1
            ;;
    esac
done

# Print timestamp
echo "========================================="
echo "Factorio Mod Packaging Script"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================="

# Run validation before packaging (unless --force is used)
if [ "$FORCE_PACKAGE" = true ]; then
    echo ""
    echo "⚠️  WARNING: Skipping validation due to --force flag"
    echo ""
else
    echo ""
    echo "Running pre-packaging validation..."
    if ! ./validate.sh; then
        echo ""
        echo "❌ Validation failed! Fix the errors above before packaging."
        echo "   Or use --force to skip validation."
        exit 1
    fi
    echo ""
fi

# Read mod name and version from info.json
MOD_NAME=$(jq -r .name info.json)
MOD_VERSION=$(jq -r .version info.json)

if [ -z "$MOD_NAME" ] || [ -z "$MOD_VERSION" ]; then
  echo "Error: Could not read mod name or version from info.json."
  echo "Please ensure info.json is present and contains 'name' and 'version' fields."
  exit 1
fi

# Create a temporary directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

# The name of the directory inside the zip file
PACKAGE_DIR="$MOD_NAME"_"$MOD_VERSION"
FULL_PACKAGE_DIR="$TMP_DIR/$PACKAGE_DIR"
mkdir -p "$FULL_PACKAGE_DIR"

# Build exclusion list from .gitignore and additional package-specific exclusions
EXCLUSIONS=""

# Read .gitignore and convert to rsync exclusions
if [ -f .gitignore ]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        if [ -n "$line" ] && [ "${line#\#}" = "$line" ]; then
            EXCLUSIONS="$EXCLUSIONS --exclude='$line'"
        fi
    done < .gitignore
fi

# Add package-specific exclusions not in .gitignore
PACKAGE_EXCLUSIONS=(
    '.git'
    'assets*'
    'mod-description.md'
    'plans*'
    'AGENTS.md'
    'CLAUDE.md'
    '.gitignore'
    '*.sh'
    '.claude*'
    'tests*'
    'validate*'
    'tests/'
    '.luacheckrc'
    '.luarc.json'
    '.DS_Store'
)

for exclusion in "${PACKAGE_EXCLUSIONS[@]}"; do
    EXCLUSIONS="$EXCLUSIONS --exclude='$exclusion'"
done

# Copy all files to the temporary directory with exclusions
eval "rsync -av $EXCLUSIONS ./ \"$FULL_PACKAGE_DIR/\""

# Create the zip file
(
  cd "$TMP_DIR"
  zip -r "$PACKAGE_DIR".zip "$PACKAGE_DIR"
)

# Move the zip file into builds/
mkdir -p builds
mv "$TMP_DIR/$PACKAGE_DIR.zip" builds/

echo "Successfully created package: builds/$PACKAGE_DIR.zip"

# Check for debug mode in core.lua and show warning at the end
if grep -rq "debug_enabled = true" scripts/ 2>/dev/null; then
    echo ""
    echo "========================================="
    echo "⚠️  WARNING: DEBUG MODE IS ENABLED!"
    echo "========================================="
    echo ""
    echo "Found 'debug_enabled = true' in scripts/"
    echo "This will cause excessive logging in production."
    echo ""
    echo "Please set 'debug_enabled = false' before packaging"
    echo "for release to users."
    echo ""
    echo "========================================="
fi
