#!/usr/bin/env bash
set -e

echo "=== 1. Verifying ADB Connection & Local APKs ==="
if ! adb get-state 1>/dev/null 2>&1; then
    echo "Error: No authorized Quest headset found. Run 'adb devices' to check connection."
    exit 1
fi

for apk in "app-debug.apk" "Android.apk"; do
    if [ ! -f "$apk" ]; then
        echo "Error: Missing $apk in the current directory."
        exit 1
    fi
done

echo "=== 2. Reading Headset Info ==="
echo "Model:       $(adb shell getprop ro.vendor.product.model_extended)"
echo "Fingerprint: $(adb shell getprop ro.build.fingerprint)"
echo "Build ID:    $(adb shell getprop ro.build.display.id)"
echo "Build Type:  $(adb shell getprop ro.build.type)"
echo "Branch:      $(adb shell getprop ro.build.branch)"

echo "=== 3. Disabling Bluetooth & Wi-Fi ==="
adb shell cmd bluetooth_manager disable
adb shell svc wifi disable

echo "=== 4. Setting Safe Low Screen Brightness ==="
# Set to 50 (out of 255) instead of 0 so the screen stays visible across reboots
adb shell settings put system screen_brightness 50
adb shell cmd display set-brightness 0.2

echo "=== 5. Installing & Starting QuestNavKeepAwake ==="
adb install -r -g app-debug.apk
adb shell pm grant com.questnav.keepawake android.permission.WRITE_SECURE_SETTINGS || true
adb shell am start -n com.questnav.keepawake/.MainActivity

echo "=== 6. Installing & Launching QuestNav ==="
adb shell pm uninstall gg.QuestNav.QuestNav || true
adb install -r -g Android.apk

echo "Launching QuestNav..."
adb shell am start -n gg.QuestNav.QuestNav/com.unity3d.player.UnityPlayerGameActivity

echo "=== Setup Complete! ==="
