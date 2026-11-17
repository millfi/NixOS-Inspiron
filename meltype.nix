{ pkgs }:

let
  inherit (pkgs) lib stdenv fetchFromGitHub callPackage cmake pkg-config
    buildDotnetModule dotnet-sdk_10 clang autoPatchelfHook zlib icu openssl
    runCommand bazel_9 python3 unzip libxcrypt-legacy fcitx5;

  version = "1.2.1-unstable-2026-10-14";
  src = fetchFromGitHub {
    owner = "yksr-melt";
    repo = "Meltype";
    rev = "45e14f86558aa6ea34f2c2ecd038ba95ca8c3c46";
    hash = "sha256-NTz4/yQx1j1EycemL40ruXnixhTiTl3DtVNkPFtqHN0=";
  };

  native = buildDotnetModule {
    pname = "meltype-native";
    inherit version src;

    projectFile = "src/Meltype.Mac.Native/Meltype.Mac.Native.csproj";
    dotnet-sdk = dotnet-sdk_10;
    selfContainedBuild = true;
    runtimeId = "linux-x64";
    nativeBuildInputs = [ clang autoPatchelfHook ];
    buildInputs = [ zlib icu openssl stdenv.cc.cc.lib ];
    dotnetFlags = [
      "-p:PublishAot=true"
      "-p:NativeLib=Shared"
      "-p:StripSymbols=true"
      "-p:IlcMaxDegreeOfParallelism=2"
    ];
    executables = [ ];

    postFixup = ''
      patchelf --add-rpath ${lib.makeLibraryPath [ icu openssl ]} "$out/lib/meltype-native/MeltypeNative.so"
    '';
  };

  mozcSource = fetchFromGitHub {
    owner = "google";
    repo = "mozc";
    rev = "a069a88d4cb5c011de0f9aebb6c149a1c808d904";
    hash = "sha256-YXjr4lZbs4uw8RZJ233FeyAtdzT7cfjil6+HNZ/ASv0=";
  };

  mozcPrepared = runCommand "meltype-mozc-source" { } ''
    cp -r ${mozcSource}/src "$out"
    chmod -R u+w "$out"
    cp ${src}/native/mozc/meltype_mozc_helper.cc "$out/converter/"
    cat ${src}/native/mozc/BUILD.fragment >> "$out/converter/BUILD.bazel"
  '';

  bazelPackage = callPackage (pkgs.path + "/pkgs/by-name/ba/bazel_9/build-support/bazelPackage.nix") { };
  mozc = (bazelPackage {
    name = "meltype-mozc-helper";
    src = mozcPrepared;
    bazel = bazel_9;
    registry = fetchFromGitHub {
      owner = "bazelbuild";
      repo = "bazel-central-registry";
      rev = "8af428d14a5d8e0c97d67594ad630793afa712d0";
      hash = "sha256-ei35WeKMOmGekLFYp6oTTWdoymH8MqEYRqnazeuDSR4=";
    };
    startupArgs = [ "--host_jvm_args=-Xmx1024m" ];
    targets = [ "//converter:meltype_mozc_helper" ];
    commandArgs = [
      "--config=oss_linux"
      "--config=release_build"
      "--jobs=2"
      "--local_resources=memory=2048"
    ];
    nativeBuildInputs = [ python3 pkg-config unzip ];
    buildInputs = [ libxcrypt-legacy ];
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
          --replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'
        mv patched-python-rule "vendor_dir/rules_python+/$file"
      done
    '';
  });

  meltype = stdenv.mkDerivation {
    pname = "fcitx5-meltype";
    inherit version src;

    nativeBuildInputs = [ cmake pkg-config ];
    buildInputs = [ fcitx5 ];
    cmakeDir = "../linux/fcitx5";
    cmakeFlags = [ "-DMELTYPE_DIR=${placeholder "out"}/lib/meltype" ];

    installPhase = ''
      runHook preInstall

      # Fcitx5 addon and input-method registration.
      install -Dm755 meltype.so "$out/lib/fcitx5/meltype.so"
      install -Dm644 "$src/linux/fcitx5/meltype-addon.conf" "$out/share/fcitx5/addon/meltype.conf"
      install -Dm644 "$src/linux/fcitx5/meltype.conf" "$out/share/fcitx5/inputmethod/meltype.conf"
      substituteInPlace "$out/share/fcitx5/inputmethod/meltype.conf" --replace-fail '@DIR@' "$out/lib/meltype"

      # Runtime assets and independently built backends.
      install -Dm644 "$src/linux/icon.png" "$out/lib/meltype/icon.png"
      mkdir -p "$out/lib/meltype/mozc"
      ln -s ${native}/lib/meltype-native/MeltypeNative.so "$out/lib/meltype/libMeltypeNative.so"
      ln -s ${mozc}/bin/meltype_mozc_helper "$out/lib/meltype/mozc/meltype_mozc_helper"

      # License notices shipped with Meltype.
      install -Dm644 "$src/LICENSE" "$out/share/licenses/meltype/LICENSE"
      install -Dm644 "$src/THIRD-PARTY-NOTICES.md" "$out/share/licenses/meltype/THIRD-PARTY-NOTICES.md"

      runHook postInstall
    '';

    passthru = { inherit native mozc; };
    meta = {
      description = "Japanese and English input method for Fcitx 5";
      homepage = "https://github.com/yksr-melt/Meltype";
      license = lib.licenses.gpl3Plus;
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  package = meltype;

  nixosModule = { config, ... }: {
    # Installed and built as part of the NixOS system, for all users.
    i18n.inputMethod = {
      enable = true;
      type = "fcitx5";
      fcitx5 = {
        addons = [ meltype ];
        waylandFrontend = true;
        settings.inputMethod = {
          "Groups/0" = {
            Name = "Default";
            "Default Layout" = "jp";
            DefaultIM = "meltype";
          };
          "Groups/0/Items/0" = { Name = "meltype"; Layout = ""; };
          GroupOrder."0" = "Default";
        };
      };
    };

    # KWin starts Fcitx with the Wayland input-method connection at next login.
    # This is a system default; per-user KDE settings can still override it.
    environment.etc."xdg/kwinrc".text = ''
      [Wayland]
      InputMethod=${config.i18n.inputMethod.package}/share/applications/org.fcitx.Fcitx5.desktop
      VirtualKeyboardEnabled=true
    '';
  };
}
