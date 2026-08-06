#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <base-trollstore.tar> <output.tar>" >&2
  exit 64
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_TAR="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTPUT_TAR="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/trollfools-integration.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

APP_ROOT="$BUILD_ROOT/package"
APP_PATH="$APP_ROOT/TrollStore.app"
BUILD_PRODUCTS="$BUILD_ROOT/BuildProducts"
BUILD_INTERMEDIATES="$BUILD_ROOT/BuildIntermediates"
TOOLS_ROOT="$BUILD_ROOT/tools"
mkdir -p "$APP_ROOT" "$TOOLS_ROOT"

tar -xf "$BASE_TAR" -C "$APP_ROOT"
if [[ ! -x "$APP_PATH/TrollStore" || ! -f "$APP_PATH/Info.plist" ]]; then
  echo "The input archive does not contain TrollStore.app." >&2
  exit 65
fi

echo "Building trollfoolscli..."
xcodebuild \
  -project "$PROJECT_ROOT/TrollFools.xcodeproj" \
  -target trollfoolscli \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$BUILD_PRODUCTS" \
  OBJROOT="$BUILD_INTERMEDIATES" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

CLI_PATH="$BUILD_PRODUCTS/Release-iphoneos/trollfoolscli"
if [[ ! -f "$CLI_PATH" ]]; then
  CLI_PATH="$(find "$BUILD_PRODUCTS" -type f -name trollfoolscli -perm +111 -print -quit)"
fi
if [[ -z "${CLI_PATH:-}" || ! -f "$CLI_PATH" ]]; then
  echo "Unable to locate the trollfoolscli build product." >&2
  exit 66
fi

echo "Building TrollFoolsIntegration.dylib..."
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=14.0 \
  -fobjc-arc \
  -fmodules \
  -O2 \
  -dynamiclib \
  -install_name '@executable_path/TrollFoolsIntegration.dylib' \
  -framework Foundation \
  -framework UIKit \
  -framework UniformTypeIdentifiers \
  "$PROJECT_ROOT/integration/TrollFoolsIntegration.m" \
  -o "$BUILD_ROOT/TrollFoolsIntegration.dylib"

echo "Building host signing and Mach-O tools..."
git clone --quiet --depth 1 --branch 2.1.1 --recurse-submodules \
  https://github.com/opa334/TrollStore.git "$TOOLS_ROOT/TrollStore"
make -s -C "$TOOLS_ROOT/TrollStore/Exploits/fastPathSign"
FAST_PATH_SIGN="$TOOLS_ROOT/TrollStore/Exploits/fastPathSign/fastPathSign"

git clone --quiet --depth 1 https://github.com/tyilo/insert_dylib.git "$TOOLS_ROOT/insert_dylib"
xcodebuild \
  -project "$TOOLS_ROOT/insert_dylib/insert_dylib.xcodeproj" \
  -target insert_dylib \
  -configuration Release \
  SYMROOT="$TOOLS_ROOT/insert_dylib-products" \
  OBJROOT="$TOOLS_ROOT/insert_dylib-intermediates" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null
INSERT_DYLIB="$(find "$TOOLS_ROOT/insert_dylib-products" -type f -name insert_dylib -perm +111 -print -quit)"
if [[ -z "$INSERT_DYLIB" ]]; then
  echo "Unable to locate the insert_dylib build product." >&2
  exit 67
fi

echo "Installing TrollFools runtime files..."
install -m 0755 "$CLI_PATH" "$APP_PATH/trollfoolscli"
install -m 0755 "$BUILD_ROOT/TrollFoolsIntegration.dylib" "$APP_PATH/TrollFoolsIntegration.dylib"

RUNTIME_EXECUTABLES=(
  chown cp cp-15 ct_bypass insert_dylib install_name_tool ldid mkdir mv mv-15 optool rm
)
RUNTIME_LIBRARIES=(
  libcrypto.3.dylib libintl.8.dylib libiosexec.1.dylib libxar.1.dylib
)
for name in "${RUNTIME_EXECUTABLES[@]}"; do
  install -m 0755 "$PROJECT_ROOT/TrollFools/$name" "$APP_PATH/$name"
done
for name in "${RUNTIME_LIBRARIES[@]}"; do
  install -m 0755 "$PROJECT_ROOT/TrollFools/$name" "$APP_PATH/$name"
done
install -m 0644 "$PROJECT_ROOT/TrollFools/CydiaSubstrate.framework.zip" \
  "$APP_PATH/CydiaSubstrate.framework.zip"

/usr/libexec/PlistBuddy -c "Add :TSRootBinaries: string trollfoolscli" "$APP_PATH/Info.plist" 2>/dev/null || true
for name in "${RUNTIME_EXECUTABLES[@]}"; do
  /usr/libexec/PlistBuddy -c "Add :TSRootBinaries: string $name" "$APP_PATH/Info.plist" 2>/dev/null || true
done

echo "Patching and signing Mach-O files..."
for name in "${RUNTIME_EXECUTABLES[@]}" "${RUNTIME_LIBRARIES[@]}"; do
  "$FAST_PATH_SIGN" "$APP_PATH/$name"
done

"$INSERT_DYLIB" \
  '@executable_path/TrollFoolsIntegration.dylib' \
  "$APP_PATH/TrollStore" \
  --inplace --overwrite --no-strip-codesig --all-yes

"$FAST_PATH_SIGN" --entitlements "$PROJECT_ROOT/integration/TrollFoolsIntegration.entitlements.plist" \
  "$APP_PATH/trollfoolscli"
"$FAST_PATH_SIGN" "$APP_PATH/TrollFoolsIntegration.dylib"
"$FAST_PATH_SIGN" "$APP_PATH/TrollStore"

cat >"$APP_PATH/TrollFoolsIntegration.txt" <<EOF
TrollFools source: $(git -C "$PROJECT_ROOT" rev-parse HEAD)
Base archive: $(shasum -a 256 "$BASE_TAR" | awk '{print $1}')
Built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "Verifying package..."
file "$APP_PATH/TrollStore" "$APP_PATH/trollfoolscli" "$APP_PATH/TrollFoolsIntegration.dylib"
otool -L "$APP_PATH/TrollStore" | grep -F '@executable_path/TrollFoolsIntegration.dylib'
codesign -d --entitlements :- "$APP_PATH/TrollStore" >/dev/null
codesign -d --entitlements :- "$APP_PATH/trollfoolscli" >/dev/null
codesign -d "$APP_PATH/TrollFoolsIntegration.dylib" >/dev/null
for name in trollfoolscli TrollFoolsIntegration.dylib CydiaSubstrate.framework.zip; do
  test -e "$APP_PATH/$name"
done
LC_ALL=C grep -aF 'plugin-state' "$APP_PATH/trollfoolscli"
LC_ALL=C grep -aF 'Download and Inject' "$APP_PATH/TrollFoolsIntegration.dylib"
LC_ALL=C grep -aF 'Plugin paused and kept for later.' "$APP_PATH/TrollFoolsIntegration.dylib"

rm -f "$OUTPUT_TAR"
COPYFILE_DISABLE=1 tar -cf "$OUTPUT_TAR" -C "$APP_ROOT" TrollStore.app
tar -tf "$OUTPUT_TAR" | grep -Fx 'TrollStore.app/TrollFoolsIntegration.dylib'
tar -tf "$OUTPUT_TAR" | grep -Fx 'TrollStore.app/trollfoolscli'
shasum -a 256 "$OUTPUT_TAR"
