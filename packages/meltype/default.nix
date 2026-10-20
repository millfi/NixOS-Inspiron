{
  lib,
  stdenv,
  fetchFromGitHub,
  callPackage,
  cmake,
  pkg-config,
  fcitx5,
}:

let
  version = "1.2.1-unstable-2026-10-14";
  src = fetchFromGitHub {
    owner = "yksr-melt";
    repo = "Meltype";
    rev = "45e14f86558aa6ea34f2c2ecd038ba95ca8c3c46";
    hash = "sha256-NTz4/yQx1j1EycemL40ruXnixhTiTl3DtVNkPFtqHN0=";
  };

  native = callPackage ./native.nix { inherit version src; };
  mozc = callPackage ./mozc.nix { meltypeSrc = src; };
in
stdenv.mkDerivation {
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
}
