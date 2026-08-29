#!/bin/bash
set -e

# ============================================================
# whaminsta - IPA Builder (LOCAL / manual fallback)
# Compiles tweak + injects into a Instagram IPA.
# NOTE: the CANONICAL build is CI (.github/workflows/build.yml,
# insert_dylib + ad-hoc codesign on a macOS runner). This local
# script exists as a manual fallback and mirrors the CI steps,
# including the clean-base strip of the bundled repacker mods.
# ============================================================

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== whaminsta IPA Builder ===${NC}"

# --- Config ---
INPUT_IPA="${1:-Input.ipa}"
OUTPUT_IPA="whaminsta.ipa"
DYLIB="obj/whaminsta.dylib"

# --- Check prerequisites ---
if ! command -v optool &> /dev/null; then
    echo -e "${RED}ERROR: optool not found. Install it first.${NC}"
    echo "  brew install optool  OR  build from https://github.com/alexzielenski/optool"
    exit 1
fi

if ! command -v ldid &> /dev/null; then
    echo -e "${RED}ERROR: ldid not found.${NC}"
    echo "  brew install ldid"
    exit 1
fi

if [ ! -f "$INPUT_IPA" ]; then
    echo -e "${RED}ERROR: $INPUT_IPA not found.${NC}"
    echo "Usage: ./build_ipa.sh <path_to_threads.ipa>"
    exit 1
fi

# --- Step 1: Build tweak ---
echo -e "${BLUE}[1/5] Building tweak...${NC}"
cd Tweak
make clean all
cd ..
ls -la "$DYLIB" || { echo -e "${RED}ERROR: Dylib not found at $DYLIB${NC}"; exit 1; }

# --- Step 2: Extract IPA ---
echo -e "${BLUE}[2/5] Extracting IPA...${NC}"
WORKDIR=$(mktemp -d)
cd "$WORKDIR"
unzip -q "/$OLDPWD/$INPUT_IPA"
APP_PATH=$(find Payload -name "*.app" -maxdepth 1 | head -1)
APP_NAME=$(basename "$APP_PATH" .app)
echo "  App: $APP_PATH"

# --- Step 2b: Strip bundled third-party mod dylibs (clean base) ---
# The Instagram repacker IPA ships four mod dylibs in Frameworks/ that are NOT
# wired via the main binary's load commands. Remove them so we inject only OUR
# dylib into a clean base. Mirrors the CI clean-base strip.
for mod in Sideloadbypass1 Sideloadbypass2 ThreadSaver blatantsPatch; do
    if [ -f "$APP_PATH/Frameworks/$mod.dylib" ]; then
        if otool -l "$APP_PATH/$APP_NAME" | grep -q "$mod.dylib"; then
            echo -e "${RED}ERROR: $mod.dylib is load-commanded — aborting strip.${NC}"; exit 1
        fi
        rm -f "$APP_PATH/Frameworks/$mod.dylib"
        echo "  removed $mod.dylib"
    fi
done

# --- Step 3: Inject dylib ---
echo -e "${BLUE}[3/5] Injecting dylib...${NC}"
mkdir -p "$APP_PATH/Frameworks"
cp "/$OLDPWD/$DYLIB" "$APP_PATH/Frameworks/whaminsta.dylib"
optool install -c load -p @executable_path/Frameworks/whaminsta.dylib -t "$APP_PATH/$APP_NAME"

# --- Step 4: Copy entitlements & re-sign ---
echo -e "${BLUE}[4/5] Signing...${NC}"
ENT="/$OLDPWD/Entitlements/threads.entitlements"

if [ -f "$ENT" ]; then
    ldid -S"$ENT" "$APP_PATH/$APP_NAME"
    echo "  Signed with custom entitlements"
else
    ldid -S "$APP_PATH/$APP_NAME"
    echo "  Ad-hoc signed"
fi

# --- Step 5: Re-package ---
echo -e "${BLUE}[5/5] Packaging IPA...${NC}"
rm -f "/$OLDPWD/$OUTPUT_IPA"
zip -r -q "/$OLDPWD/$OUTPUT_IPA" Payload/

# Cleanup
cd "$OLDPWD"
rm -rf "$WORKDIR"

echo ""
echo -e "${GREEN}=== Done! ===${NC}"
echo -e "Output: ${GREEN}$OUTPUT_IPA${NC}"
echo "Install via Sideloadly or: ios-deploy --bundle $OUTPUT_IPA"
