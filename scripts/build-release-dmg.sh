#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Canope.xcodeproj}"
PROJECT_SPEC_PATH="${PROJECT_SPEC_PATH:-$ROOT_DIR/project.yml}"
SCHEME="${SCHEME:-Canope}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-Canope}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
STAGE_DIR="${STAGE_DIR:-$BUILD_ROOT/dmg-stage}"
VOLNAME="${VOLNAME:-Canope}"
VERSION_SUFFIX="${VERSION_SUFFIX:-}"

if [[ -n "$VERSION_SUFFIX" ]]; then
  DMG_NAME="${APP_NAME}-${VERSION_SUFFIX}.dmg"
else
  DMG_NAME="${APP_NAME}.dmg"
fi

DMG_PATH="${DMG_PATH:-$BUILD_ROOT/$DMG_NAME}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  if [[ -f "$PROJECT_SPEC_PATH" ]] && command -v xcodegen >/dev/null 2>&1; then
    echo "==> Generating Xcode project from $(basename "$PROJECT_SPEC_PATH")"
    (cd "$ROOT_DIR" && xcodegen generate)
  else
    echo "Missing Xcode project at $PROJECT_PATH and xcodegen is unavailable." >&2
    exit 1
  fi
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  clean
  build
)

if [[ -n "${CODE_SIGN_STYLE_OVERRIDE:-}" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_STYLE=${CODE_SIGN_STYLE_OVERRIDE}")
fi

if [[ -n "${CODE_SIGN_IDENTITY_OVERRIDE:-}" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY_OVERRIDE}")
fi

if [[ -n "${DEVELOPMENT_TEAM_OVERRIDE:-}" ]]; then
  XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM_OVERRIDE}")
fi

if [[ -n "${ENABLE_HARDENED_RUNTIME_OVERRIDE:-}" ]]; then
  XCODEBUILD_ARGS+=("ENABLE_HARDENED_RUNTIME=${ENABLE_HARDENED_RUNTIME_OVERRIDE}")
fi

echo "==> Building ${APP_NAME}.app (${CONFIGURATION})"
xcodebuild "${XCODEBUILD_ARGS[@]}"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH" >&2
  exit 1
fi

xattr -cr "$APP_PATH" || true

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"

echo "==> Creating DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> DMG ready"
echo "$DMG_PATH"
