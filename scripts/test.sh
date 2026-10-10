#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

xcrun swift test --package-path "$PROJECT_ROOT/Packages/TagMP3Core"
xcodebuild \
  -project "$PROJECT_ROOT/TagMP3/TagMP3.xcodeproj" \
  -scheme TagMP3 \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  test
