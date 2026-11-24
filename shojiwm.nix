{ pkgs }:

let
  inherit (pkgs)
    lib
    fetchFromGitHub
    rustPlatform
    pkg-config
    makeWrapper
    addDriverRunpath
    linux-pam
    fontconfig
    freetype
    libxkbcommon
    libxcb
    wayland
    vulkan-loader
    libglvnd
    mesa
    cliphist
    wl-clipboard
    zenity
    playerctl
    bibata-cursors
    util-linux
    python3
    ;

  runtimeLibraryPath = lib.makeLibraryPath [
    wayland
    libxkbcommon
    libxcb
    fontconfig
    freetype
    vulkan-loader
    libglvnd
    mesa
  ];

  driverSearchPath =
    subdir:
    lib.concatStringsSep ":" [
      "${addDriverRunpath.driverLink}/${subdir}"
      "${mesa}/${subdir}"
    ];

  shoji-bar-4 = rustPlatform.buildRustPackage rec {
    pname = "shoji-bar-4";
    version = "0.1.0-unstable-2026-11-14";

    src = fetchFromGitHub {
      owner = "bea4dev";
      repo = "shoji-bar-4";
      rev = "636b9ebb18a27468103add94939b34738faa8a30";
      hash = "sha256-eG5AEMrPrLbYY1i9voDwOAlHdmX6s+cRpQ6yITsZqqk=";
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      outputHashes = {
        "anti-webui-0.1.0" = "sha256-srPYJ2n6/wDNzCjYQ4r6wotCRwspaiqBLh+1e1SufEA=";
      };
    };

    nativeBuildInputs = [
      pkg-config
      makeWrapper
    ];

    buildInputs = [
      linux-pam
      fontconfig
      freetype
      libxkbcommon
      libxcb
      wayland
    ];

    doCheck = false;

    postFixup = ''
      wrapProgram "$out/bin/shoji-bar-4" \
        --prefix LD_LIBRARY_PATH : "${addDriverRunpath.driverLink}/lib:${runtimeLibraryPath}" \
        --suffix LIBGL_DRIVERS_PATH : "${driverSearchPath "lib/dri"}" \
        --suffix __EGL_VENDOR_LIBRARY_DIRS : "${driverSearchPath "share/glvnd/egl_vendor.d"}"
    '';

    meta = {
      description = "Material 3 Expressive desktop shell for ShojiWM";
      homepage = "https://github.com/bea4dev/shoji-bar-4";
      license = with lib.licenses; [ mit asl20 ];
      platforms = [ "x86_64-linux" "aarch64-linux" ];
      mainProgram = "shoji-bar-4";
    };
  };
in
{
  package = shoji-bar-4;

  nixosModule =
    { config, lib, ... }:
    let
      cfg = config.programs.shojiwm;
      desktopCfg = config.programs.shojiwmDesktop;

      patchScript = pkgs.writeScript "shojiwm-patch-config" ''
        #!${python3}/bin/python3
        import pathlib
        import sys

        config_path = pathlib.Path(sys.argv[1])
        home_dir = sys.argv[2]
        shell_cmd = sys.argv[3]
        terminal_cmd = sys.argv[4]
        browser_cmd = sys.argv[5]

        if not config_path.is_file():
            sys.exit(0)

        text = config_path.read_text(encoding="utf-8")
        updated = text

        for old_shell in (
            'const SHELL = "~/.config/shoji-bar-4/target/release/shoji-bar-4";',
            f'const SHELL = "{home_dir}/.config/shoji-bar-4/target/release/shoji-bar-4";',
        ):
            updated = updated.replace(old_shell, f'const SHELL = "{shell_cmd}";')

        updated = updated.replace(
            '    keyboard: {\n      options: "caps:ctrl_modifier",',
            '    keyboard: {\n      layout: "jp",\n      options: "caps:ctrl_modifier",',
        )

        updated = updated.replace(
            '\n  input.device["Razer Razer Blade Keyboard"] = {\n    keyboard: {\n      layout: "us",\n    },\n  };',
            "",
        )

        updated = updated.replace(
            'COMPOSITOR.process.spawn({ command: ["kitty"] });',
            f'COMPOSITOR.process.spawn({{ command: ["{terminal_cmd}"] }});',
        )

        old_chrome = (
            'COMPOSITOR.key.bind("chrome", "Super+B", () => {\n'
            '  COMPOSITOR.process.spawn({\n'
            '    command:\n'
            '      "google-chrome-stable --enable-features=OzonePlatform --ozone-platform=wayland",\n'
            '  });\n'
            '});'
        )
        new_browser = (
            'COMPOSITOR.key.bind("browser", "Super+B", () => {\n'
            f'  COMPOSITOR.process.spawn({{ command: ["{browser_cmd}"] }});\n'
            '});'
        )
        updated = updated.replace(old_chrome, new_browser)

        if updated != text:
            config_path.write_text(updated, encoding="utf-8")
      '';
    in
    {
      options.programs.shojiwmDesktop = {
        enableShell = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Install shoji-bar-4 and its runtime dependencies for ShojiWM.";
        };

        terminal = lib.mkOption {
          type = lib.types.str;
          default = "konsole";
          description = "Terminal command substituted into newly initialized ShojiWM configs.";
        };

        browser = lib.mkOption {
          type = lib.types.str;
          default = "firefox";
          description = "Browser command substituted into newly initialized ShojiWM configs.";
        };
      };

      config = lib.mkIf (cfg.enable && desktopCfg.enableShell) {
        environment.systemPackages = [
          shoji-bar-4
          cliphist
          wl-clipboard
          zenity
          playerctl
          bibata-cursors
        ];

        services.upower.enable = lib.mkDefault true;
        services.power-profiles-daemon.enable = lib.mkDefault true;

        system.activationScripts.shojiwm-desktop-config = lib.mkIf cfg.initConfig.enable (
          lib.stringAfter [ "shojiwm-init-config" ] (
            lib.concatMapStringsSep "\n" (
              user:
              let
                userConfig = config.users.users.${user};
                home = userConfig.home or "/home/${user}";
                indexPath = "${home}/.config/shojiwm/src/index.tsx";
              in
              ''
                if [ -f ${lib.escapeShellArg indexPath} ]; then
                  ${util-linux}/bin/runuser -u ${lib.escapeShellArg user} -- \
                    ${patchScript} \
                    ${lib.escapeShellArg indexPath} \
                    ${lib.escapeShellArg home} \
                    "shoji-bar-4" \
                    ${lib.escapeShellArg desktopCfg.terminal} \
                    ${lib.escapeShellArg desktopCfg.browser}
                fi
              ''
            ) cfg.initConfig.users
          )
        );
      };
    };
}
