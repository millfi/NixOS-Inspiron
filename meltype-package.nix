{ pkgs }:
let
  inherit (pkgs) lib;
  version = "1.2.1-unstable-2026-10-14";
  src = pkgs.fetchFromGitHub {
    owner = "yksr-melt";
    repo = "Meltype";
    rev = "45e14f86558aa6ea34f2c2ecd038ba95ca8c3c46";
    hash = "sha256-NTz4/yQx1j1EycemL40ruXnixhTiTl3DtVNkPFtqHN0=";
  };
  native = pkgs.buildDotnetModule {
    pname = "meltype-native";
    inherit version src;
    projectFile = "src/Meltype.Mac.Native/Meltype.Mac.Native.csproj";
    dotnet-sdk = pkgs.dotnet-sdk_10;
    selfContainedBuild = true;
    runtimeId = "linux-x64";
    nativeBuildInputs = [ pkgs.clang pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.zlib pkgs.icu pkgs.openssl pkgs.stdenv.cc.cc.lib ];
    dotnetFlags = [ "-p:PublishAot=true" "-p:NativeLib=Shared" "-p:StripSymbols=true" "-p:IlcMaxDegreeOfParallelism=2" ];
    executables = [ ];
    postFixup = ''
      patchelf --add-rpath ${lib.makeLibraryPath [ pkgs.icu pkgs.openssl ]} "$out/lib/meltype-native/MeltypeNative.so"
    '';
  };
  mozcSource = pkgs.fetchFromGitHub {
    owner = "google";
    repo = "mozc";
    rev = "a069a88d4cb5c011de0f9aebb6c149a1c808d904";
    hash = "sha256-YXjr4lZbs4uw8RZJ233FeyAtdzT7cfjil6+HNZ/ASv0=";
  };
  mozcPrepared = pkgs.runCommand "meltype-mozc-source" { } ''
    cp -r ${mozcSource}/src "$out"
    chmod -R u+w "$out"
    cp ${src}/native/mozc/meltype_mozc_helper.cc "$out/converter/"
    cat ${src}/native/mozc/BUILD.fragment >> "$out/converter/BUILD.bazel"
  '';
  bazelPackage = pkgs.callPackage (pkgs.path + "/pkgs/by-name/ba/bazel_9/build-support/bazelPackage.nix") { };
  mozc = (bazelPackage {
    name = "meltype-mozc-helper";
    src = mozcPrepared;
    bazel = pkgs.bazel_9;
    registry = pkgs.fetchFromGitHub {
      owner = "bazelbuild";
      repo = "bazel-central-registry";
      rev = "8af428d14a5d8e0c97d67594ad630793afa712d0";
      hash = "sha256-ei35WeKMOmGekLFYp6oTTWdoymH8MqEYRqnazeuDSR4=";
    };
    startupArgs = [ "--host_jvm_args=-Xmx1024m" ];
    targets = [ "//converter:meltype_mozc_helper" ];
    commandArgs = [ "--config=oss_linux" "--config=release_build" "--jobs=2" "--local_resources=memory=2048" ];
    nativeBuildInputs = [ pkgs.python3 pkgs.pkg-config pkgs.unzip ];
    buildInputs = [ pkgs.libxcrypt-legacy ];
    bazelVendorDepsFOD = {
      outputHash = "sha256-bj2sBF+H7d7MraYSTlpTW+cHNBamKCmaaQ/1O74Ftgs=";
      outputHashAlgo = "sha256";
    };
    installPhase = ''
      install -Dm755 bazel-bin/converter/meltype_mozc_helper "$out/bin/meltype_mozc_helper"
      install -Dm644 ${mozcSource}/LICENSE "$out/share/licenses/meltype-mozc/LICENSE"
      install -Dm644 data/installer/credits_en.html "$out/share/licenses/meltype-mozc/CREDITS.html"
    '';
  }).overrideAttrs (old: {
    # Bazel generates Python launchers after Nix's usual shebang patch phase.
    # Replace their template defaults without modifying the vendored store paths.
    preBuildPhase = old.preBuildPhase + ''
      for file in python/private/py_runtime_info.bzl python/private/py_executable.bzl; do
        substitute "${old.bazelVendorDeps}/vendor_dir/rules_python+/$file" patched-python-rule \
          --replace-fail '#!/usr/bin/env python3' '#!${pkgs.python3}/bin/python3'
        mv patched-python-rule "vendor_dir/rules_python+/$file"
      done
    '';
  });
in
pkgs.stdenv.mkDerivation {
  pname = "fcitx5-meltype";
  inherit version src;
  nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
  buildInputs = [ pkgs.fcitx5 ];
  cmakeDir = "../linux/fcitx5";
  cmakeFlags = [ "-DMELTYPE_DIR=${placeholder "out"}/lib/meltype" ];
  installPhase = ''
    runHook preInstall
    install -Dm755 meltype.so "$out/lib/fcitx5/meltype.so"
    install -Dm644 ../linux/fcitx5/meltype-addon.conf "$out/share/fcitx5/addon/meltype.conf"
    install -Dm644 ../linux/fcitx5/meltype.conf "$out/share/fcitx5/inputmethod/meltype.conf"
    substituteInPlace "$out/share/fcitx5/inputmethod/meltype.conf" --replace-fail '@DIR@' "$out/lib/meltype"
    install -Dm644 ../linux/icon.png "$out/lib/meltype/icon.png"
    mkdir -p "$out/lib/meltype/mozc"
    ln -s ${native}/lib/meltype-native/MeltypeNative.so "$out/lib/meltype/libMeltypeNative.so"
    ln -s ${mozc}/bin/meltype_mozc_helper "$out/lib/meltype/mozc/meltype_mozc_helper"
    install -Dm644 ../LICENSE "$out/share/licenses/meltype/LICENSE"
    install -Dm644 ../THIRD-PARTY-NOTICES.md "$out/share/licenses/meltype/THIRD-PARTY-NOTICES.md"
    runHook postInstall
  '';
  passthru = { inherit native mozc; };
  meta = {
    description = "Japanese and English input method for Fcitx 5";
    homepage = "https://github.com/yksr-melt/Meltype";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
