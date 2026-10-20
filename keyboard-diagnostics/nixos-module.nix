{ config, lib, pkgs, ... }:

let
  cfg = config.services.keyboardDiagnostics;
  keyboardDiagnostics = pkgs.stdenv.mkDerivation {
    pname = "keyboard-diagnostics";
    version = "1.0.0";
    src = ./.;
    buildPhase = ''
      runHook preBuild
      $CC -std=c11 -O2 -Wall -Wextra -Werror keyboard-diagnostics.c -o keyboard-diagnostics
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 keyboard-diagnostics $out/bin/keyboard-diagnostics
      runHook postInstall
    '';
  };
in
{
  options.services.keyboardDiagnostics.enable = lib.mkEnableOption
    "privacy-preserving keyboard input diagnostics";

  config = lib.mkIf cfg.enable {
    systemd.services.keyboard-diagnostics = {
      description = "Aggregate keyboard input diagnostics";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udevd.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${keyboardDiagnostics}/bin/keyboard-diagnostics";
        Restart = "on-failure";
        RestartSec = "3s";
        User = "root";
        Group = "root";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "keyboard-diagnostics";
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/input/event* r" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateTmp = true;
        PrivateDevices = false;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
