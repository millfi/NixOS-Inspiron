{
  callPackage,
  path,
  fetchFromGitHub,
  runCommand,
  bazel_9,
  python3,
  pkg-config,
  unzip,
  libxcrypt-legacy,
  meltypeSrc,
}:

let
  mozcSource = fetchFromGitHub {
    owner = "google";
    repo = "mozc";
    rev = "a069a88d4cb5c011de0f9aebb6c149a1c808d904";
    hash = "sha256-YXjr4lZbs4uw8RZJ233FeyAtdzT7cfjil6+HNZ/ASv0=";
  };

  mozcPrepared = runCommand "meltype-mozc-source" { } ''
    cp -r ${mozcSource}/src "$out"
    chmod -R u+w "$out"
    cp ${meltypeSrc}/native/mozc/meltype_mozc_helper.cc "$out/converter/"
    cat ${meltypeSrc}/native/mozc/BUILD.fragment >> "$out/converter/BUILD.bazel"
  '';

  bazelPackage = callPackage (path + "/pkgs/by-name/ba/bazel_9/build-support/bazelPackage.nix") { };
in
(bazelPackage {
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
})
