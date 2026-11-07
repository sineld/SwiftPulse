#!/bin/zsh
# Builds a Release app bundle into dist/SwiftPulse.app (ad-hoc signed unless DEVELOPMENT_TEAM is set in project.yml).
set -e
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project SwiftPulse.xcodeproj -scheme SwiftPulse -configuration Release \
  -derivedDataPath .build/DerivedData build CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  -skipPackagePluginValidation -skipMacroValidation | grep -E "error:|warning: .*Sources|BUILD (SUCCEEDED|FAILED)" || true
rm -rf dist/SwiftPulse.app
mkdir -p dist
cp -R .build/DerivedData/Build/Products/Release/SwiftPulse.app dist/
echo "dist/SwiftPulse.app ready"
