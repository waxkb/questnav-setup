# QuestNav Setup

One-shot setup for a USB-connected Quest headset: builds QuestNavKeepAwake,
downloads the latest QuestNav APK, configures the headset, and installs + launches
both apps.

## Linux

Requirements: nix (`nix-shell`), adb, git, curl, python3 — already provided by the
nix environment, or install them yourself.

```sh
./setup-questnav.sh
```

The nix shell provides the JDK 17 and Android SDK used to build QuestNavKeepAwake
(same build the Windows script does, just via nix instead of a local Android SDK).

## Windows

Requirements: Windows 10/11, PowerShell 5.1+, and `winget` (App Installer, preinstalled
on Windows 11; on Windows 10 install it from the Microsoft Store or run
`Add-WindowsCapability -Online -Name Microsoft.DesktopAppInstaller` in an elevated prompt).

```powershell
powershell -ExecutionPolicy Bypass -File setup-questnav.ps1
```

What the script does:

1. Installs missing dependencies via winget (Git) — nothing is persisted to the Windows
   user/machine environment except Git's PATH entry (standard for a winget install)
2. Uses a system JDK 17+ if one is on PATH, otherwise installs a local Eclipse Temurin 17
   into `%LOCALAPPDATA%\QuestNav\jdk-17`. Either way, nothing is written to the registry:
   `JAVA_HOME` and `PATH` are session-only variables for the gradle build.
3. Installs the Android SDK command-line tools (+ platform-tools, platform 33, build-tools
   33.0.2) into `%LOCALAPPDATA%\QuestNav\android-sdk` (no global machine install)
4. Builds QuestNavKeepAwake with gradle (`gradlew.bat assembleDebug`)
5. Downloads the latest non-draft `.apk` from the QuestNav GitHub releases page
   (or uses a local `Android.apk` if one is already present)
6. Configures the headset over USB (bluetooth off, screen brightness 0.004) and
   installs/launches QuestNavKeepAwake and QuestNav

Notes:
- The Android SDK, the local JDK (if used), and all build outputs are stored under
  `%LOCALAPPDATA%\QuestNav\` or the repo folder — nothing is installed system-wide and
  the environment is never modified persistently. Re-running the script reuses what exists.
- If a system JDK 17+ is available it is used untouched and nothing new is downloaded.
- Make sure the Quest headset is connected via USB and authorized for USB debugging
  before running the script.
- `QuestNavKeepAwake/` and `Android.apk` are gitignored.

## Headset config

When the script finishes, browse to `http://<IP>:5801` on the headset network to set
your team number, then turn off wifi when you are done.
