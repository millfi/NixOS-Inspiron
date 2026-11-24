{ lib, python3, writeShellScriptBin }:

(writeShellScriptBin "cpu-monitor" ''
  exec ${python3}/bin/python3 ${./cpu-monitor.py} "$@"
'').overrideAttrs (_: {
  meta = {
    description = "Read CPU power, limits, frequency, usage and temperature";
    platforms = lib.platforms.linux;
    mainProgram = "cpu-monitor";
  };
})
