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

    # Keep the desktop entry's window class through AntiWebUI's app parser.
    # Flatpak Vivaldi uses Vivaldi-flatpak instead of its desktop file ID.
    postPatch = ''
      substituteInPlace "$cargoDepsCopy/anti-webui-wayland-shell-0.1.0/src/apps.rs" \
        --replace-fail '    pub generic_name: Option<String>,' \
          '    pub generic_name: Option<String>,
          pub startup_wm_class: Option<String>,' \
        --replace-fail '        generic_name: g.string("GenericName"),' \
          '        generic_name: g.string("GenericName"),
              startup_wm_class: g.string("StartupWMClass"),'
      substituteInPlace src/appinfo.rs \
        --replace-fail '        .or_else(|| all.iter().find(|a| last(bare(&a.id)) == last(&lower)))' \
          '        .or_else(|| all.iter().find(|a| a.startup_wm_class.as_deref()
              .is_some_and(|class| class.eq_ignore_ascii_case(app_id))))
              .or_else(|| all.iter().find(|a| last(bare(&a.id)) == last(&lower)))'
    '';

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
    { config, lib, options, ... }:
    let
      cfg = config.programs.shojiwm;
      desktopCfg = config.programs.shojiwmDesktop;

      # Wrap the installed compositor without rebuilding it. Preserve the
      # upstream module's xwayland overrides and its single SDDM session entry.
      sessionPackage = lib.makeOverridable (
        { xwayland ? pkgs.xwayland, xwaylandSatellite ? null }:
        let
          compositor = options.programs.shojiwm.package.default.override {
            inherit xwayland xwaylandSatellite;
          };
          launcher = pkgs.writeShellScript "shojiwm-session" ''
            if [[ " $* " != *" --tty "* ]]; then
              unset SHOJIWM_MANAGED_SESSION
              exec ${compositor}/bin/shoji_wm "$@"
            fi

            export SHOJIWM_MANAGED_SESSION=1
            cleanup() {
              ${pkgs.systemd}/bin/systemctl --user stop shojiwm-session.target || true
            }
            trap cleanup EXIT
            ${compositor}/bin/shoji_wm "$@" &
            compositor_pid=$!
            trap 'kill -TERM "$compositor_pid" 2>/dev/null || true' HUP INT TERM
            wait "$compositor_pid"
            result=$?
            # A signal can interrupt wait before the compositor has exited.
            if kill -0 "$compositor_pid" 2>/dev/null; then
              wait "$compositor_pid"
              result=$?
            fi
            exit "$result"
          '';
        in
        pkgs.symlinkJoin {
          name = "shojiwm-session-${compositor.version}";
          paths = [ compositor ];
          postBuild = ''
            rm "$out/bin/shoji_wm"
            ln -s ${launcher} "$out/bin/shoji_wm"
            rm "$out/share/wayland-sessions/shojiwm.desktop"
            substitute ${compositor}/share/wayland-sessions/shojiwm.desktop \
              "$out/share/wayland-sessions/shojiwm.desktop" \
              --replace-fail "Exec=${compositor}/bin/shoji_wm" "Exec=$out/bin/shoji_wm"
          '';
          passthru.providedSessions = [ "shojiwm" ];
        }
      ) { };

      desktopShell = pkgs.writeShellScriptBin "shojiwm-desktop-shell" ''
        # ShojiWM has created its Wayland socket before starting this command.
        # Nested compositors must not take over the host graphical session.
        if [[ "''${SHOJIWM_MANAGED_SESSION:-}" == 1 ]]; then
          env_keys=()
          for key in WAYLAND_DISPLAY DISPLAY SHOJIWM_SOCKET XDG_CURRENT_DESKTOP \
            XDG_SESSION_DESKTOP XDG_SESSION_TYPE DESKTOP_SESSION XDG_MENU_PREFIX \
            PAM_KWALLET5_LOGIN; do
            if [[ -v "$key" ]]; then env_keys+=("$key"); fi
          done
          ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd "''${env_keys[@]}"
          ${lib.optionalString desktopCfg.enableKWallet ''
            if [[ -n "''${PAM_KWALLET5_LOGIN:-}" && -S "$PAM_KWALLET5_LOGIN" ]]; then
              ${pkgs.kdePackages.kwallet-pam}/libexec/pam_kwallet_init
            fi
          ''}
          ${pkgs.systemd}/bin/systemctl --user start shojiwm-session.target
        fi
        exec ${shoji-bar-4}/bin/shoji-bar-4 "$@"
      '';

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
            'const SHELL = "shoji-bar-4";',
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

        enableKWallet = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Unlock KWallet with PAM and use its Secret portal in ShojiWM.";
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
        programs.shojiwm.package = lib.mkDefault sessionPackage;

        environment.systemPackages = [
          shoji-bar-4
          desktopShell
          cliphist
          wl-clipboard
          zenity
          playerctl
          bibata-cursors
        ];

        services.upower.enable = lib.mkDefault true;
        services.power-profiles-daemon.enable = lib.mkDefault true;

        systemd.user.targets.shojiwm-session = {
          description = "ShojiWM graphical session";
          bindsTo = [ "graphical-session.target" ];
          wants = [ "graphical-session-pre.target" ];
          after = [ "graphical-session-pre.target" ];
        };

        security.pam.services.login.kwallet.enable = lib.mkIf desktopCfg.enableKWallet true;
        xdg.portal = lib.mkIf (cfg.portal.enable && desktopCfg.enableKWallet) {
          extraPortals = [ pkgs.kdePackages.kwallet ];
          config.shojiwm."org.freedesktop.impl.portal.Secret" = [ "kwallet" ];
        };

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
                    "shojiwm-desktop-shell" \
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
