{ config, lib, pkgs, ... }:

let
  cfg = config.services.cpuPl1;
  defaults = { power-saver = 18; balanced = 28; performance = 35; };
  powerLimitPath = "/sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw";
  settings = pkgs.writeText "cpu-pl1.json" (builtins.toJSON {
    inherit (cfg) powerLimits pollIntervalSeconds temperatureLimitCelsius temperatureResumeCelsius;
    inherit powerLimitPath;
    busctl = "${pkgs.systemd}/bin/busctl";
    hwmonPath = "/sys/class/hwmon";
  });
  daemon = pkgs.writeText "cpu-pl1.py" (builtins.readFile ./daemon.py);
in
{
  options.services.cpuPl1 = {
    enable = lib.mkEnableOption "CPU PL1 control following the active power profile";

    powerLimits = lib.mkOption {
      default = { };
      description = "Sustained CPU package power in watts for each power profile.";
      type = lib.types.submodule {
        options = lib.mapAttrs (profile: watts: lib.mkOption {
          type = lib.types.ints.between 1 35;
          default = watts;
          description = "PL1 in watts for the ${profile} profile.";
        }) defaults;
      };
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.ints.between 1 60;
      default = 2;
      description = "Interval between profile, temperature and PL1 checks.";
    };

    temperatureLimitCelsius = lib.mkOption {
      type = lib.types.ints.between 50 90;
      default = 88;
      description = "Stop increasing PL1 and cap it at 18 W above this CPU temperature.";
    };

    temperatureResumeCelsius = lib.mkOption {
      type = lib.types.ints.between 30 89;
      default = 80;
      description = "Resume the selected power limit after cooling to this temperature.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.temperatureResumeCelsius < cfg.temperatureLimitCelsius;
      message = "services.cpuPl1.temperatureResumeCelsius must be below temperatureLimitCelsius.";
    }];

    boot.kernelModules = [ "coretemp" ];
    services.power-profiles-daemon.enable = true;

    systemd.services.cpu-pl1 = {
      description = "Maintain CPU PL1 for the active power profile";
      wantedBy = [ "multi-user.target" ];
      wants = [ "power-profiles-daemon.service" ];
      # PPD starts after multi-user.target. Waiting for it here creates a boot
      # ordering cycle; the daemon already retries until its D-Bus API is ready.
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 -u ${daemon} --config ${settings}";
        Restart = "on-failure";
        RestartSec = "5s";
        User = "root";
        Group = "root";
        SyslogIdentifier = "cpu-pl1";
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        # Only this hardware setting is writable in the service's mount namespace.
        ReadWritePaths = [ powerLimitPath ];
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
