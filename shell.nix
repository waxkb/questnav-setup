{
  pkgs ? import <nixpkgs> { config.allowUnfree = true; },
}:

let
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    buildToolsVersions = [
      "33.0.1"
      "33.0.2"
    ];
    platformVersions = [ "33" ];
    includeEmulator = false;
    includeSources = false;
    includeSystemImages = false;
    useGoogleAPIs = false;
  };
in
pkgs.mkShell {
  buildInputs = [
    pkgs.jdk17
    androidComposition.androidsdk
  ];

  shellHook = ''
    export ANDROID_HOME="${androidComposition.androidsdk}/libexec/android-sdk"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export JAVA_HOME="${pkgs.jdk17}"
  '';
}
