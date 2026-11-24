#!/usr/bin/env bash
set -euo pipefail

export NIXPKGS_ACCEPT_ANDROID_SDK_LICENSE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_NIX="$SCRIPT_DIR/shell.nix"
KEEPAWAKE_DIR="$SCRIPT_DIR/QuestNavKeepAwake"
KEEPAWAKE_APK="$KEEPAWAKE_DIR/app/build/outputs/apk/debug/app-debug.apk"
QUESTNAV_APK="$SCRIPT_DIR/Android.apk"

echo "=== 1. Checking Prerequisites & ADB Connection ==="
if [ ! -f "$SHELL_NIX" ]; then
    echo "Error: shell.nix not found at $SHELL_NIX"
    exit 1
fi

for cmd in adb git curl python3 nix-shell; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

if ! adb get-state >/dev/null 2>&1; then
    echo "Error: No authorized Quest headset found. Check USB cable and 'adb devices'."
    exit 1
fi

echo "=== 2. Managing QuestNavKeepAwake Repository & Build ==="
if [ -d "$KEEPAWAKE_DIR/.git" ]; then
    echo "Updating existing QuestNavKeepAwake repository..."
    git -C "$KEEPAWAKE_DIR" pull --ff-only || true
else
    echo "Cloning QuestNavKeepAwake..."
    git clone https://github.com/QuestNav/QuestNavKeepAwake.git "$KEEPAWAKE_DIR"
fi

if [ ! -f "$KEEPAWAKE_APK" ]; then
    echo "Building QuestNavKeepAwake inside nix-shell..."
    rm -f "$KEEPAWAKE_DIR/local.properties"
    nix-shell "$SHELL_NIX" --run "cd \"$KEEPAWAKE_DIR\" && ./gradlew assembleDebug"
else
    echo "KeepAwake APK already built, skipping compilation."
fi

if [ ! -f "$KEEPAWAKE_APK" ]; then
    echo "Error: $KEEPAWAKE_APK was not found."
    exit 1
fi

echo "=== 3. Checking for Latest QuestNav Release ==="
LATEST_APK_URL=$(curl -sL "https://api.github.com/repos/QuestNav/QuestNav/releases" | python3 -c '
import json, sys
try:
    releases = json.load(sys.stdin)
    for rel in releases:
        if rel.get("draft"):
            continue
        for asset in rel.get("assets", []):
            if asset.get("name", "").endswith(".apk"):
                print(asset["browser_download_url"])
                sys.exit(0)
except Exception:
    sys.exit(1)
')

if [ -z "$LATEST_APK_URL" ]; then
    echo "Warning: Could not query GitHub releases API. Falling back to local Android.apk if available."
elif [ ! -f "$QUESTNAV_APK" ]; then
    echo "Downloading latest QuestNav APK: $LATEST_APK_URL"
    curl -fL "$LATEST_APK_URL" -o "$QUESTNAV_APK"
else
    echo "QuestNav APK already exists locally, skipping download."
fi

if [ ! -f "$QUESTNAV_APK" ]; then
    echo "Error: No QuestNav APK found locally or via GitHub."
    exit 1
fi

echo "=== 4. Reading Headset Info ==="
echo "Model:       $(adb shell getprop ro.vendor.product.model_extended)"
echo "Fingerprint: $(adb shell getprop ro.build.fingerprint)"
echo "Build ID:    $(adb shell getprop ro.build.display.id)"

echo "=== 5. Configuring Radios & Minimum Visible Brightness ==="
adb shell cmd bluetooth_manager disable
# adb shell svc wifi disable
adb shell settings put system screen_brightness 1
adb shell cmd display set-brightness 0.004

echo "=== 6. Checking & Installing QuestNavKeepAwake ==="
if adb shell pm list packages | grep -q "com.questnav.keepawake"; then
    echo "QuestNavKeepAwake already installed, ensuring permissions..."
else
    echo "Installing QuestNavKeepAwake..."
    adb install -r -g "$KEEPAWAKE_APK"
fi
adb shell pm grant com.questnav.keepawake android.permission.WRITE_SECURE_SETTINGS || true
adb shell am start -n com.questnav.keepawake/.MainActivity

echo "=== 7. Checking & Installing QuestNav ==="
if adb shell pm list packages | grep -q "gg.QuestNav.QuestNav"; then
    echo "QuestNav is already installed. Updating in place..."
else
    echo "Installing QuestNav..."
fi
adb install -r -g "$QUESTNAV_APK"

echo "Launching QuestNav..."
adb shell am start -n gg.QuestNav.QuestNav/com.unity3d.player.UnityPlayerGameActivity

echo "=== Script Complete! ==="
echo "Now go to http://<IP>:5801 to set your team number and turn wifi off when you're done."
