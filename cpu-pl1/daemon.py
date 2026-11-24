"""Maintain only the MMIO package PL1; leave thermal protection and PL2 intact."""

import argparse
import json
import logging
from pathlib import Path
import signal
import subprocess
import threading
import time


LOG = logging.getLogger("cpu-pl1")


class Controller:
    def __init__(self, settings, dry_run=False):
        self.settings = settings
        self.limit_path = Path(settings["powerLimitPath"])
        self.hwmon_path = Path(settings["hwmonPath"])
        self.dry_run = dry_run
        self.guarded = False
        self.previous_state = None
        self.original_limit = None
        self.last_written = None
        self.last_messages = {}

    def report(self, key, message, *args):
        """Rate limit repeated firmware resets and transient read failures."""
        now = time.monotonic()
        if now - self.last_messages.get(key, float("-inf")) >= 30:
            LOG.info(message, *args)
            self.last_messages[key] = now

    def profile(self):
        try:
            result = subprocess.run(
                [self.settings["busctl"], "--system", "--json=short", "--timeout=2",
                 "get-property", "org.freedesktop.UPower.PowerProfiles",
                 "/org/freedesktop/UPower/PowerProfiles",
                 "org.freedesktop.UPower.PowerProfiles", "ActiveProfile"],
                check=True, capture_output=True, text=True, timeout=3,
            )
            value = json.loads(result.stdout)["data"]
            if value not in self.settings["powerLimits"]:
                raise ValueError(f"Unknown profile: {value!r}")
            return value
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
            self.report("profile", "Cannot read power profile; using power-saver: %s", error)
            return "power-saver"

    def temperature(self):
        temperatures = []
        for device in self.hwmon_path.glob("hwmon*"):
            try:
                if device.joinpath("name").read_text().strip() != "coretemp":
                    continue
                for sensor in device.glob("temp*_input"):
                    value = int(sensor.read_text())
                    if 0 < value <= 125000:
                        temperatures.append(value / 1000)
            except (OSError, ValueError):
                continue
        return max(temperatures) if temperatures else None

    def tick(self):
        # Validate the constraint before opening any hardware setting for writing.
        if self.limit_path.with_name("constraint_0_name").read_text().strip() != "long_term":
            raise ValueError("The selected powercap constraint is not PL1")
        current = int(self.limit_path.read_text())
        maximum = min(35000000, int(self.limit_path.with_name("constraint_0_max_power_uw").read_text()))
        if current <= 0 or maximum <= 0:
            raise ValueError("Invalid powercap power limit")
        if self.original_limit is None:
            self.original_limit = current

        profile = self.profile()
        temperature = self.temperature()
        if temperature is None or temperature >= self.settings["temperatureLimitCelsius"]:
            self.guarded = True
        elif temperature <= self.settings["temperatureResumeCelsius"]:
            self.guarded = False

        target = min(self.settings["powerLimits"][profile] * 1000000, maximum)
        if self.guarded:
            # Respect even lower firmware limits while hot or without a working sensor.
            target = min(target, 18000000, current)

        state = (profile, self.guarded)
        if state != self.previous_state:
            LOG.info("Profile=%s, temperature=%s C, thermal guard=%s, target=%.1f W",
                     profile, temperature, self.guarded, target / 1000000)
            self.previous_state = state

        if current == target:
            return
        if self.dry_run:
            LOG.info("Dry run: would set PL1 %.1f -> %.1f W", current / 1000000, target / 1000000)
            return
        self.limit_path.write_text(f"{target}\n")
        self.last_written = target
        actual = int(self.limit_path.read_text())
        self.report("write", "PL1 %.1f -> %.1f W (read back %.1f W)",
                    current / 1000000, target / 1000000, actual / 1000000)

    def restore(self):
        """Undo our last write on a normal stop without undoing a firmware change."""
        if self.dry_run or self.last_written is None:
            return
        try:
            current = int(self.limit_path.read_text())
            if current != self.last_written or current == self.original_limit:
                return
            if self.original_limit > current:
                temperature = self.temperature()
                if temperature is None or temperature > self.settings["temperatureResumeCelsius"]:
                    LOG.info("Leaving the lower PL1 in place while the CPU is hot")
                    return
            self.limit_path.write_text(f"{self.original_limit}\n")
            LOG.info("Restored starting PL1: %.1f W", self.original_limit / 1000000)
        except (OSError, ValueError) as error:
            LOG.warning("Cannot restore starting PL1: %s", error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    settings = json.loads(args.config.read_text())
    controller = Controller(settings, args.dry_run)
    stopped = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.set())
    try:
        while not stopped.is_set():
            try:
                controller.tick()
            except (OSError, ValueError) as error:
                controller.report("tick", "Cannot update PL1: %s", error)
            if args.once:
                break
            stopped.wait(settings["pollIntervalSeconds"])
    finally:
        if not args.once:
            controller.restore()


if __name__ == "__main__":
    main()
