#!/bin/bash

# This script packages the Factorio mod for release.
# It reads the mod name and version from info.json, creates a zip file
# named quality-gardener_<version>.zip, and excludes the .git directory.
#
# This is the Factorio 2.0 branch: the zip goes to builds/ and is never
# installed locally — a 2.0 mod is rejected outright by a 2.1 game, so the
# build is only useful in a 2.0 playtester's hands. The zip keeps the canonical
# {mod-name}_{version} filename because Factorio will not load it otherwise,
# which makes the folder the only safe place to keep the two release lines
# from tangling.

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

# Where finished builds land. Listed in .gitignore, which is also where the
# rsync exclusion below picks it up from — a build must never package itself.
BUILD_DIR="builds"

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

# Create the build and archive folders if they don't exist
mkdir -p "$BUILD_DIR" archive

# Move any previous build to the archive folder, leaving one current zip in
# builds/. Scoped to BUILD_DIR so a zip built from the 2.1 branch is untouched.
if ls "$BUILD_DIR/${MOD_NAME}"_*.zip 1> /dev/null 2>&1; then
    echo "Moving previous builds to archive folder..."
    mv "$BUILD_DIR/${MOD_NAME}"_*.zip archive/
fi

# Create the zip file
(
  cd "$TMP_DIR"
  zip -r "$PACKAGE_DIR".zip "$PACKAGE_DIR"
)

# Move the zip file to the build folder
mv "$TMP_DIR/$PACKAGE_DIR.zip" "$BUILD_DIR/"

echo "Successfully created package: $BUILD_DIR/$PACKAGE_DIR.zip"

# Deliberately not installed locally — see the note at the top of this script.
echo ""
echo "========================================="
echo "Factorio 2.0 build — not installed locally"
echo "========================================="
echo ""
echo "Send this file to a playtester running Factorio 2.0.46 or newer:"
echo "  $(pwd)/$BUILD_DIR/$PACKAGE_DIR.zip"
echo ""
echo "They drop it into their mods folder unchanged — Factorio only loads a mod"
echo "zip named {mod-name}_{version}, so $PACKAGE_DIR.zip must keep its name."
echo ""
echo "Packaged at: $(date '+%Y-%m-%d %H:%M:%S %Z')"

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
