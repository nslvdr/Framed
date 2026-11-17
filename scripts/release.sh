#!/usr/bin/env bash
# Builds a universal Framed.app, zips it and publishes it as a GitHub release that
# scripts/install.sh picks up. Usage: scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is dirty; commit first." >&2; exit 1; }

# Sign with the self-signed release identity (see scripts/make-signing-cert.sh), never a
# personal Apple Development one: its name would ship inside the public app.
security find-certificate -c "Framed Release" >/dev/null 2>&1 \
    || { echo "Missing \"Framed Release\" identity; run scripts/make-signing-cert.sh." >&2; exit 1; }
ARCHS="arm64 x86_64" VERSION="$VERSION" SIGN_IDENTITY="Framed Release" scripts/bundle.sh
ZIP="build/Framed.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Framed.app "$ZIP" # ditto keeps the code signature intact

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Framed $VERSION" --generate-notes
