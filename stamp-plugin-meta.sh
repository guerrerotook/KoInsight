#!/bin/bash

# Writes the released version and the GitHub repository slug into the KOReader
# plugin's _meta.lua. Both values are read at runtime by plugin_metadata.lua and
# drive the plugin's self-updater, so every artifact that ships the plugin
# (the GitHub Release zip and the Docker image) has to be stamped the same way.
#
# Usage: ./stamp-plugin-meta.sh <version> <owner/repo>

set -eu

VERSION=${1:-}
REPOSITORY=${2:-}

if [ -z "$VERSION" ] || [ -z "$REPOSITORY" ]; then
  echo "Usage: $0 <version> <owner/repo>" >&2
  exit 1
fi

if ! printf '%s' "$VERSION" |
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'; then
  echo "Invalid version: '$VERSION' (expected semver, e.g. 1.2.3)" >&2
  exit 1
fi

if ! printf '%s' "$REPOSITORY" | grep -Eq '^[0-9A-Za-z._-]+/[0-9A-Za-z._-]+$'; then
  echo "Invalid repository: '$REPOSITORY' (expected owner/repo)" >&2
  exit 1
fi

META_FILE="$(dirname "$0")/plugins/koinsight.koplugin/_meta.lua"

sed -i "s~\(version = \)\"[^\"]*\"~\1\"$VERSION\"~" "$META_FILE"
sed -i "s~\(repository = \)\"[^\"]*\"~\1\"$REPOSITORY\"~" "$META_FILE"

grep -q "version = \"$VERSION\"" "$META_FILE"
grep -q "repository = \"$REPOSITORY\"" "$META_FILE"

cat "$META_FILE"
