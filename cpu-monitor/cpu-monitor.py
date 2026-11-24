#!/usr/bin/env python3
"""Read CPU telemetry without changing power limits or requesting privileges.

Power is the RAPL package energy delta (including the package's integrated GPU).
Clock is a snapshot averaged across CPUs, not a busy-only hardware measurement.
"""

import argparse
from datetime import datetime
import math
from pathlib import Path
import sys
import time


def read_text(path):
    try:
        return path.read_text().strip()
    except (OSError, UnicodeError):
        return None


def read_int(path):
    try:
        return int(read_text(path))
    except (TypeError, ValueError):
        return None


class RaplPackage:
    def __init__(self, domains):
        # MSR and MMIO can describe the same package: never add them together.
        self.domains = domains
        self.energy_path = None
        self.energy_range = None
        self.previous_energy = None
        for domain in domains:
            energy = read_int(domain / "energy_uj")
            energy_range = read_int(domain / "max_energy_range_uj")
            if energy is not None and energy_range and energy_range > 0:
                self.energy_path = domain / "energy_uj"
                self.energy_range = energy_range
                break

    def limit(self, name):
        limits = []
        for domain in self.domains:
            if read_int(domain / "enabled") == 0:
                continue
            for label in domain.glob("constraint_*_name"):
                if read_text(label) == name:
                    value = read_int(label.with_name(
                        label.name.removesuffix("name") + "power_limit_uw"
                    ))
                    if value is not None and value > 0:
                        limits.append(value / 1_000_000)
        # Both interfaces can impose a limit. Show the tighter active limit.
        return min(limits) if limits else None

    def power(self):
        if self.energy_path is None:
            return None
        energy = read_int(self.energy_path)
        now = time.monotonic()
        previous = self.previous_energy
        self.previous_energy = (energy, now) if energy is not None else None
        if energy is None or previous is None or now <= previous[1]:
            return None
        delta = energy - previous[0]
        if delta < 0:
            delta += self.energy_range
        return delta / 1_000_000 / (now - previous[1]) if delta >= 0 else None


def discover_packages():
    packages = {}
    for domain in sorted(Path("/sys/class/powercap").glob("intel-rapl*:*")):
        name = read_text(domain / "name")
        if name and name.startswith("package-"):
            packages.setdefault(name, []).append(domain)
    return [RaplPackage(domains) for domains in packages.values()]


def cpu_ticks():
    try:
        with Path("/proc/stat").open() as source:
            fields = source.readline().split()
        if fields[0] != "cpu":
            return None
        # guest and guest_nice are already included in user and nice.
        ticks = [int(value) for value in fields[1:9]]
        return sum(ticks), ticks[3] + ticks[4]
    except (OSError, ValueError, IndexError):
        return None


def clock_ghz():
    total = 0
    count = 0
    for policy in Path("/sys/devices/system/cpu/cpufreq").glob("policy*"):
        khz = read_int(policy / "scaling_cur_freq")
        if khz is not None and khz > 0:
            weight = len((read_text(policy / "affected_cpus") or "0").split())
            total += khz * weight
            count += weight
    if count:
        return total / count / 1_000_000
    cpuinfo = read_text(Path("/proc/cpuinfo")) or ""
    mhz = []
    for line in cpuinfo.splitlines():
        if line.startswith("cpu MHz"):
            try:
                mhz.append(float(line.split(":", 1)[1]))
            except (ValueError, IndexError):
                continue
    return sum(mhz) / len(mhz) / 1000 if mhz else None


def temperature_c():
    values = []
    for hwmon in Path("/sys/class/hwmon").glob("hwmon*"):
        if read_text(hwmon / "name") in {"coretemp", "k10temp", "zenpower"}:
            values.extend(read_int(path) for path in hwmon.glob("temp*_input"))
    values = [value for value in values if value is not None]
    if not values:
        for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
            if read_text(zone / "type") in {"x86_pkg_temp", "cpu-thermal"}:
                value = read_int(zone / "temp")
                if value is not None:
                    values.append(value)
    return max(values) / 1000 if values else None


def complete_sum(values):
    return sum(values) if values and all(v is not None for v in values) else None


class Monitor:
    def __init__(self):
        self.packages = discover_packages()
        self.power_available = bool(self.packages) and all(
            package.energy_path is not None for package in self.packages
        )
        self.previous_ticks = None

    def sample(self):
        ticks = cpu_ticks()
        previous = self.previous_ticks
        self.previous_ticks = ticks
        usage = None
        if ticks is not None and previous is not None:
            total = ticks[0] - previous[0]
            idle = ticks[1] - previous[1]
            if total > 0 and idle >= 0:
                usage = min(100.0, max(0.0, 100 * (total - idle) / total))
        return {
            "power": complete_sum([p.power() for p in self.packages]),
            "pl1": complete_sum([p.limit("long_term") for p in self.packages]),
            "pl2": complete_sum([p.limit("short_term") for p in self.packages]),
            "clock": clock_ghz(),
            "usage": usage,
            "temperature": temperature_c(),
        }


def positive_interval(value):
    try:
        number = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("interval must be a positive number")
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("interval must be a positive finite number")
    return number


def positive_count(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("count must be a positive integer")
    if number < 1:
        raise argparse.ArgumentTypeError("count must be a positive integer")
    return number


def main():
    parser = argparse.ArgumentParser(
        description="Display readable CPU sensors every second; never requests sudo.",
        epilog=("Unreadable sensors are omitted. Power uses package energy deltas; "
                "PL1/PL2 show the tighter active MSR/MMIO limits. Clock is a "
                "sampled CPU average; temperature is the hottest CPU sensor."),
    )
    parser.add_argument("--interval", type=positive_interval, default=1.0,
                        metavar="SECONDS", help="sampling interval (default: 1)")
    parser.add_argument("--count", type=positive_count, metavar="N",
                        help="stop after N samples (default: run until Ctrl+C)")
    args = parser.parse_args()
    monitor = Monitor()
    first = monitor.sample()
    columns = [
        ("power", "CPU Power(W)", 12, 1),
        ("pl1", "PL1(W)", 8, 1),
        ("pl2", "PL2(W)", 8, 1),
        ("clock", "Clock(GHz)", 11, 2),
        ("usage", "Usage(%)", 10, 1),
        ("temperature", "Temp(°C)", 10, 1),
    ]
    available = {key for key, value in first.items() if value is not None}
    if monitor.power_available:
        available.add("power")
    if monitor.previous_ticks is not None:
        available.add("usage")
    columns = [column for column in columns if column[0] in available]
    if not columns:
        parser.exit(1, "No readable CPU sensors found.\n")
    if not monitor.power_available:
        print("CPU Power: package energy counter unavailable; column omitted.",
              file=sys.stderr)
    print("Time     " + " ".join(f"{label:>{width}}" for _, label, width, _ in columns),
          flush=True)
    interactive = sys.stdout.isatty()
    deadline = time.monotonic() + args.interval
    count = 0
    try:
        while args.count is None or count < args.count:
            time.sleep(max(0.0, deadline - time.monotonic()))
            sample = monitor.sample()
            cells = []
            for key, _, width, precision in columns:
                value = sample[key]
                cells.append(f"{value:>{width}.{precision}f}" if value is not None
                             else f"{'-':>{width}}")
            row = datetime.now().strftime("%H:%M:%S") + " " + " ".join(cells)
            # Clear the previous reading before drawing the next one in place.
            print(("\r\033[2K" if interactive else "") + row,
                  end="" if interactive else "\n", flush=True)
            count += 1
            deadline += args.interval
            if deadline <= time.monotonic():
                deadline = time.monotonic() + args.interval
    finally:
        # Leave the shell prompt on a new line after Ctrl+C or --count finishes.
        if interactive:
            print(flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
