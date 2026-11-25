#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a Quest headset for QuestNav on Windows (USB).

.DESCRIPTION
    - Installs missing dependencies via winget (Git), plus a local Eclipse Temurin JDK 17 if none is available
    - Installs Android SDK command-line tools + platform-tools + platform 33 + build-tools
    - Configures the USB connection to the Quest headset
    - Builds QuestNavKeepAwake (local gradle build, mirrors the Linux nix-shell build)
    - Downloads the latest QuestNav APK from GitHub releases (or uses a local Android.apk)
    - Configures the headset (minimum brightness, bluetooth off) and installs + launches the apps

    On Linux use setup-questnav.sh instead (requires nix-shell + nix android SDK).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup-questnav.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir    = $PSScriptRoot
$KeepAwakeDir = Join-Path $ScriptDir 'QuestNavKeepAwake'
$KeepAwakeApk = Join-Path $KeepAwakeDir 'app', 'build', 'outputs', 'apk', 'debug', 'app-debug.apk'
$QuestNavApk  = Join-Path $ScriptDir 'Android.apk'

$LocalAppData = $env:LOCALAPPDATA
if (-not $LocalAppData) {
    if ($env:USERPROFILE) {
        $LocalAppData = Join-Path $env:USERPROFILE 'AppData\Local'
    } elseif ($env:HOME) {
        # Non-Windows fallback (the script is Windows-only in practice, but don't crash).
        $LocalAppData = $env:HOME
    } else {
        $LocalAppData = $PWD.Path
    }
}
$SdkRoot      = Join-Path $LocalAppData 'QuestNav' 'android-sdk'
$CmdLineRoot  = Join-Path $SdkRoot 'cmdline-tools' 'latest'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-Command([string]$Name, [string]$Hint) {
    if (-not (Test-Command $Name)) {
        throw "Required command '$Name' is not installed or not in PATH. $Hint"
    }
}

function Refresh-Path {
    # Pick up PATH entries written by installers (e.g. winget) without restarting the shell.
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ((@($machine, $user) | Where-Object { $_ }) -join ';')
}

function Test-JavaVersion([int]$Major) {
    if (-not (Test-Command 'java')) { return $false }
    try {
        $out = (& java -version 2>&1 | Out-String)
        if ($out -match 'version "(\d+)') { return [int]$Matches[1] -ge $Major }
    } catch { }
    return $false
}

function Add-JavaToPathFromKnownInstalls {
    # Fallback: after a winget install the user PATH sometimes only applies in new shells.
    # Find java.exe under the usual install roots and use it for this session.
    $roots = @(
        'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Microsoft',
        'C:\Program Files\Java',
        'C:\Program Files (x86)\Eclipse Adoptium',
        'C:\Program Files (x86)\Microsoft',
        'C:\Program Files (x86)\Java'
    )
    $javaExe = Get-ChildItem -Path $roots -Recurse -Depth 4 -Filter 'java.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($javaExe) {
        $env:Path = "$(Split-Path $javaExe.FullName -Parent);$env:Path"
        return $true
    }
    return $false
}

function Find-ApkUrl {
    # Mirrors the bash version: first non-draft release (newest first) with an .apk asset.
    try {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/QuestNav/QuestNav/releases' -Headers @{
            'User-Agent' = 'questnav-setup.ps1'
            'Accept'     = 'application/vnd.github+json'
        }
    } catch {
        return $null
    }
    foreach ($rel in $releases) {
        if ($rel.draft) { continue }
        foreach ($asset in @($rel.assets)) {
            if ($asset.name -like '*.apk') { return $asset.browser_download_url }
        }
    }
    return $null
}

function Invoke-AdbShell([string]$CommandLine) {
    $parts = $CommandLine -split ' '
    $out = & adb shell @parts
    if ($null -eq $out) { return '' }
    if ($out -is [array]) { $out = $out[0] }
    return "$out".Trim()
}

function Assert-UsbConnected {
    $deviceState = "$(& adb get-state 2>&1)".Trim()
    if ($LASTEXITCODE -ne 0 -or $deviceState -ne 'device') {
        throw "No authorized Quest headset found (adb: $deviceState). Check the USB cable and run 'adb devices'. Accept USB debugging on the headset."
    }
}

# Fail fast on a missing headset if an adb is already available (e.g. from Android Studio);
# otherwise the post-SDK check in step 3 covers it.
if (Test-Command 'adb') {
    Write-Step '0. Checking USB connection'
    Assert-UsbConnected
}

# ---------------------------------------------------------------------------
# Step 1: Prerequisites (winget will install what is missing)
# ---------------------------------------------------------------------------

Write-Step '1. Checking prerequisites'

$needsWinget = -not (Test-Command 'git')
if ($needsWinget -and -not (Test-Command 'winget')) {
    throw "winget is not available. Install App Installer (or run 'Add-WindowsCapability -Online -Name Microsoft.DesktopAppInstaller' in an elevated prompt), then re-run. Alternatively, install Git manually and put it on PATH."
}

# --- Git ---
if (-not (Test-Command 'git')) {
    Write-Host 'Installing Git via winget (Git.Git)...'
    winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install Git (exit code $LASTEXITCODE). Install Git from https://git-scm.com/download/win and re-run."
    }
    Refresh-Path
    Require-Command 'git' 'Installed Git but it is not on PATH. Open a new terminal and re-run, or add git to PATH manually.'
}

# --- JDK 17 (no system-wide changes) ---
# If a system JDK 17+ is already on PATH we use it as-is. Otherwise we download a
# local Temurin 17 into the script's data folder and use it for this session only.
# Neither path touches the Windows user/machine environment: JAVA_HOME and PATH
# are set as session variables for the gradle build and nothing is written to the
# registry (no winget JDK install, so no persistent JAVA_HOME/PATH entries).
$localJdkDir = Join-Path $LocalAppData 'QuestNav' 'jdk-17'

function Test-LocalJdk {
    $javaExe = Join-Path $localJdkDir 'bin' 'java.exe'
    if (-not (Test-Path $javaExe)) { return $false }
    try {
        $out = (& $javaExe -version 2>&1 | Out-String)
        return ($out -match 'version "(\d+)' -and [int]$Matches[1] -ge 17)
    } catch { return $false }
}

function Install-LocalJdk17 {
    Write-Host 'Installing a local Eclipse Temurin JDK 17 (no system-wide changes)...'
    $zipUrl = 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse'
    $zip = Join-Path $env:TEMP 'temurin-17-jdk.zip'
    $extractDir = Join-Path $env:TEMP 'jdk-17-extract'

    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 900

    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force
    $extracted = Get-ChildItem -Path $extractDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $extracted) { throw 'Unexpected layout in the Temurin JDK download (expected a single jdk-* folder).' }

    if (Test-Path $localJdkDir) { Remove-Item $localJdkDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $localJdkDir -Parent) | Out-Null
    Move-Item -Path $extracted.FullName -Destination $localJdkDir -Force

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

$systemJdkFound = $false
if (Test-JavaVersion 17) {
    $systemJdkFound = $true
} else {
    Refresh-Path
    if (Test-JavaVersion 17) {
        $systemJdkFound = $true
    } else {
        # PATH from a fresh shell may be stale (e.g. a JDK added by an installer): hunt for it.
        Add-JavaToPathFromKnownInstalls
        if (Test-JavaVersion 17) { $systemJdkFound = $true }
    }
}

if (-not $systemJdkFound) {
    if (-not (Test-LocalJdk)) {
        Install-LocalJdk17
    }
    if (-not (Test-LocalJdk)) {
        throw "Could not use a system JDK 17 or install a local one. Expected a JDK under $localJdkDir (or put a JDK 17+ on PATH and re-run)."
    }
    $env:Path = "$(Join-Path $localJdkDir 'bin');$env:Path"
} else {
    Write-Host 'Using the system JDK 17+ already on PATH (left untouched).'
}

Require-Command 'java' 'No JDK 17 is available and the local install failed. Install one from https://adoptium.net and put it on PATH.'

# Point gradle at the JDK for this session only. Nothing is persisted.
$javaCommand = Get-Command java -ErrorAction SilentlyContinue
if ($javaCommand) {
    $env:JAVA_HOME = Split-Path -Parent (Split-Path -Parent $javaCommand.Source)
}

# ---------------------------------------------------------------------------
# Step 2: Android SDK (command-line tools + platform-tools + platform 33)
# ---------------------------------------------------------------------------

$sdkmanager = Join-Path $CmdLineRoot 'bin\sdkmanager.bat'
if (-not (Test-Path $sdkmanager)) {
    Write-Step '2a. Installing Android SDK command-line tools'

    $zipUrl = 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip'
    $zip = Join-Path $env:TEMP 'cmdline-tools-win.zip'
    $extractDir = Join-Path $env:TEMP 'cmdline-tools-extract'

    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 900

    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force
    $extracted = Join-Path $extractDir 'cmdline-tools'
    if (-not (Test-Path $extracted)) { throw 'Unexpected layout in the cmdline-tools download (expected a cmdline-tools/ folder inside the archive).' }

    New-Item -ItemType Directory -Force -Path (Join-Path $SdkRoot 'cmdline-tools') | Out-Null
    if (Test-Path $CmdLineRoot) { Remove-Item $CmdLineRoot -Recurse -Force }
    Move-Item -Path $extracted -Destination $CmdLineRoot -Force

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Accept licenses. sdkmanager reads one y per prompt, so feed plenty.
Write-Step '2b. Accepting Android SDK licenses'
$yFile = Join-Path $env:TEMP 'android-sdk-licenses-y.txt'
1..50 | ForEach-Object { 'y' } | Out-File -FilePath $yFile -Encoding ascii
cmd /c "type `"$yFile`" | `"$sdkmanager`" --sdk_root=`"$SdkRoot`" --licenses" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to accept Android SDK licenses (sdkmanager exited with $LASTEXITCODE)."
}
Remove-Item $yFile -Force -ErrorAction SilentlyContinue

# Install platform-tools, platform 33, build-tools 33.0.2 (matches the Linux nix shell).
Write-Step '2c. Installing Android SDK packages'
& $sdkmanager --sdk_root="$SdkRoot" 'platform-tools' 'platforms;android-33' 'build-tools;33.0.2'
if ($LASTEXITCODE -ne 0) {
    throw "sdkmanager failed to install platform-tools / platforms;android-33 / build-tools;33.0.2 (exit code $LASTEXITCODE)."
}

# Use our platform-tools adb for this session.
$env:Path = "$(Join-Path $SdkRoot 'platform-tools');$env:Path"
# Same as the Linux nix shell: let the gradle build find the SDK via ANDROID_HOME.
$env:ANDROID_HOME = $SdkRoot
$env:ANDROID_SDK_ROOT = $SdkRoot

Require-Command 'adb' "adb is not on PATH after the SDK install. Expected it at $(Join-Path $SdkRoot 'platform-tools')."

# ---------------------------------------------------------------------------
# Step 3: USB connection check (fail fast, before cloning or building)
# ---------------------------------------------------------------------------

Write-Step '3. Checking USB connection'
Assert-UsbConnected

# ---------------------------------------------------------------------------
# Step 4: QuestNavKeepAwake repo & build
# ---------------------------------------------------------------------------

Write-Step '4a. Managing QuestNavKeepAwake repository'
if (Test-Path (Join-Path $KeepAwakeDir '.git')) {
    Write-Host 'Updating existing QuestNavKeepAwake repository...'
    try {
        & git -C "$KeepAwakeDir" pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Warning 'git pull failed; continuing with the local repository.' }
    } catch {
        Write-Warning "git pull failed; continuing with the local repository. $($_.Exception.Message)"
    }
} else {
    Write-Host 'Cloning QuestNavKeepAwake...'
    & git clone https://github.com/QuestNav/QuestNavKeepAwake.git "$KeepAwakeDir"
    if ($LASTEXITCODE -ne 0) { throw "Failed to clone QuestNavKeepAwake (exit code $LASTEXITCODE)." }
}

if (-not (Test-Path $KeepAwakeApk)) {
    Write-Step '4b. Building QuestNavKeepAwake'
    # Avoid a stale local.properties pointing at a different SDK location.
    Remove-Item (Join-Path $KeepAwakeDir 'local.properties') -Force -ErrorAction SilentlyContinue
    & (Join-Path $KeepAwakeDir 'gradlew.bat') --no-daemon assembleDebug
    if ($LASTEXITCODE -ne 0) { throw "Gradle build failed (exit code $LASTEXITCODE). See the output above." }
} else {
    Write-Host 'KeepAwake APK already built, skipping compilation.'
}

if (-not (Test-Path $KeepAwakeApk)) {
    throw "$KeepAwakeApk was not found after the build."
}

# ---------------------------------------------------------------------------
# Step 5: QuestNav APK (latest release or local file)
# ---------------------------------------------------------------------------

Write-Step '5. Checking for the latest QuestNav release'
$apkUrl = Find-ApkUrl
if (-not $apkUrl) {
    Write-Host 'Warning: Could not query the GitHub releases API. Falling back to the local Android.apk if available.'
} elseif (-not (Test-Path $QuestNavApk)) {
    Write-Host "Downloading latest QuestNav APK: $apkUrl"
    Invoke-WebRequest -Uri $apkUrl -OutFile $QuestNavApk -UseBasicParsing -TimeoutSec 900 -Headers @{ 'User-Agent' = 'questnav-setup.ps1' }
} else {
    Write-Host 'QuestNav APK already exists locally, skipping download.'
}

if (-not (Test-Path $QuestNavApk)) {
    throw 'No QuestNav APK found locally or via the GitHub releases API.'
}

# ---------------------------------------------------------------------------
# Step 6: Read headset info & configure
# ---------------------------------------------------------------------------

Write-Step '6a. Reading headset info'
Write-Host "Model:       $(Invoke-AdbShell 'getprop ro.vendor.product.model_extended')"
Write-Host "Fingerprint: $(Invoke-AdbShell 'getprop ro.build.fingerprint')"
Write-Host "Build ID:    $(Invoke-AdbShell 'getprop ro.build.display.id')"

Write-Step '6b. Configuring radios & minimum visible brightness'
& adb shell cmd bluetooth_manager disable
# adb shell svc wifi disable   # (left commented out, same as the bash script)
& adb shell settings put system screen_brightness 1
& adb shell cmd display set-brightness 0.004

# ---------------------------------------------------------------------------
# Step 7: QuestNavKeepAwake -- install & launch
# ---------------------------------------------------------------------------

Write-Step '7. Installing QuestNavKeepAwake'
$packages = @(& adb shell pm list packages)
if ($packages -match 'com\.questnav\.keepawake') {
    Write-Host 'QuestNavKeepAwake already installed, ensuring permissions...'
} else {
    Write-Host 'Installing QuestNavKeepAwake...'
    & adb install -r -g "$KeepAwakeApk"
    if ($LASTEXITCODE -ne 0) { throw "Failed to install QuestNavKeepAwake (exit code $LASTEXITCODE)." }
}
# Match the bash script: grant is best-effort.
$null = & adb shell pm grant com.questnav.keepawake android.permission.WRITE_SECURE_SETTINGS 2>&1
& adb shell am start -n com.questnav.keepawake/.MainActivity

# ---------------------------------------------------------------------------
# Step 8: QuestNav -- install & launch
# ---------------------------------------------------------------------------

Write-Step '8. Installing QuestNav'
if ($packages -match 'gg\.QuestNav\.QuestNav') {
    Write-Host 'QuestNav is already installed. Updating in place...'
} else {
    Write-Host 'Installing QuestNav...'
}
& adb install -r -g "$QuestNavApk"
if ($LASTEXITCODE -ne 0) { throw "Failed to install QuestNav (exit code $LASTEXITCODE)." }

Write-Host 'Launching QuestNav...'
& adb shell am start -n gg.QuestNav.QuestNav/com.unity3d.player.UnityPlayerGameActivity

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '=== Script complete! ===' -ForegroundColor Green
Write-Host 'Now go to http://<IP>:5801 to set your team number and turn wifi off when you are done.'
