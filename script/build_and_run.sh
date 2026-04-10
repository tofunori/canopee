#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Canope"
BUNDLE_ID="com.canope.app"
PROJECT_PATH="Canope.xcodeproj"
SCHEME="Canope"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/CodexDerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  xcodebuild \
    -project "$ROOT_DIR/$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build
}

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stream_process_logs() {
  /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
}

stream_telemetry_logs() {
  /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
}

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
}

stop_running_app
build_app

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built app bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    stream_process_logs
    ;;
  --telemetry|telemetry)
    open_app
    stream_telemetry_logs
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    usage
    ;;
esac
