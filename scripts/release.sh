#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="$1"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.2.0"
    exit 1
fi

# Validate version format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be in format X.Y.Z (e.g., 0.2.0)"
    exit 1
fi

TAG="v$VERSION"

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: Tag $TAG already exists"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Create a temp file for the changelog
CHANGELOG_FILE=$(mktemp)
trap 'rm -f "$CHANGELOG_FILE"' EXIT

# Use changelog.sh to generate the changelog
"$SCRIPT_DIR/changelog.sh" "$VERSION" > "$CHANGELOG_FILE"

echo ""
echo "=========================================="
echo "PROPOSED CHANGELOG FOR $TAG"
echo "=========================================="
cat "$CHANGELOG_FILE"
echo ""
echo "=========================================="
echo ""

# Ask for confirmation
read -p "Accept this changelog and create release $TAG? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Release cancelled."
    exit 0
fi

# Create the tag with changelog as message
echo "Creating tag $TAG..."
git tag -a "$TAG" -m "Release $VERSION

$(cat $CHANGELOG_FILE)"

echo "Pushing tag to origin..."
git push origin "$TAG"
git push origin HEAD

echo ""
echo "Release $TAG created and pushed successfully!"
echo ""
echo "GitHub release URL: https://github.com/wesm/roborev/releases/tag/$TAG"
