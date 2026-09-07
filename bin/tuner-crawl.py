#!/usr/bin/env python3
"""Device-tunable crawler for cockpit-tuner.

Scans /sys for per-device tunables (block queues, CPU frequency scaling,
physical NICs) and regenerates the device section of schemas.json. Generated
entries carry "generated": true and category "device - <type> - <subtype>";
re-running replaces exactly those entries, so hand-written schemas are never
touched. Device categories are opt-in in the UI: they only appear when their
category chip is explicitly selected.

Usage:
  bin/tuner-crawl.py            # print what would be generated
  bin/tuner-crawl.py --write    # update ../schemas.json in place
"""

import json
import os
import re
import sys

SCHEMAS = os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "schemas.json")

SKIP_BLOCK = re.compile(r"^(loop|zram|ram|sr)")


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def bracket_current(raw):
    if raw is None:
        return None
    m = re.search(r"\[([^\]]+)\]", raw)
    return m.group(1) if m else raw


def block_entries():
    out = []
    for dev in sorted(os.listdir("/sys/block")):
        if SKIP_BLOCK.match(dev):
            continue
        q = "/sys/block/%s/queue" % dev
        if not os.path.isdir(q):
            continue
        rotational = read(q + "/rotational")
        kind = "hdd" if rotational == "1" else "ssd"
        sched_raw = read(q + "/scheduler") or ""
        choices = [c.strip("[]") for c in sched_raw.split() if c]
        cat = "device - disk - " + dev

        out.append({
            "id": "disk.%s.scheduler" % dev,
            "title": "%s I/O scheduler" % dev,
            "description": "Block I/O scheduler for %s (%s). 'none' suits fast NVMe (the device reorders internally); mq-deadline adds fairness for SATA; bfq favors desktop interactivity on slower disks." % (dev, kind),
            "group": "aggressive", "category": cat, "risk": "medium",
            "generated": True,
            "source": "https://docs.redhat.com (RHEL 9 disk-scheduler guide) / kernel block docs",
            "default": bracket_current(sched_raw) or "—",
            "recommended": ("none — kernel default for multi-queue NVMe and Red Hat's explicit recommendation; leave it"
                            if kind == "ssd" and dev.startswith("nvme")
                            else "mq-deadline (Ubuntu/kernel default for single-queue; bfq for desktop latency, none/kyber for max IOPS — contested)"),
            "choices": choices,
            "live": {"type": "procfile-bracket", "path": q + "/scheduler"},
            "persistent": {"type": "none"},
            "edit": {"class": "sysfs"},
            "verify": "cat %s/scheduler" % q,
            "rollback": "Echo the previous scheduler back; runtime-only, reboot restores the kernel default."
        })
        out.append({
            "id": "disk.%s.read_ahead_kb" % dev,
            "title": "%s read-ahead (KB)" % dev,
            "description": "Kernel readahead window for %s. Larger helps sequential reads; smaller reduces wasted I/O for random workloads." % dev,
            "group": "aggressive", "category": cat, "risk": "low",
            "generated": True,
            "source": "Linux mm: VM_READAHEAD_PAGES (SZ_128K), include/linux/mm.h",
            "default": read(q + "/read_ahead_kb") or "128",
            "recommended": "128 (kernel mm default, not per-device-tuned) – raise to 256–512 only for sequential-heavy use",
            "range": {"min": 0, "max": 16384},
            "live": {"type": "procfile", "path": q + "/read_ahead_kb"},
            "persistent": {"type": "none"},
            "edit": {"class": "sysfs"},
            "verify": "cat %s/read_ahead_kb" % q,
            "rollback": "Echo the previous value back; runtime-only."
        })
        out.append({
            "id": "disk.%s.nr_requests" % dev,
            "title": "%s queue depth (nr_requests)" % dev,
            "description": "Requests the block layer queues for %s before throttling submitters." % dev,
            "group": "info", "category": cat, "risk": "low",
            "generated": True,
            "default": read(q + "/nr_requests") or "—",
            "recommended": "device default",
            "live": {"type": "procfile", "path": q + "/nr_requests"},
            "persistent": {"type": "none"},
            "verify": "cat %s/nr_requests" % q,
            "rollback": "n/a (informational)"
        })
    return out


def cpufreq_entries():
    base = "/sys/devices/system/cpu/cpu0/cpufreq"
    if not os.path.isdir(base):
        return []
    cat = "device - cpu - cpufreq"
    out = []
    govs = (read(base + "/scaling_available_governors") or "").split()
    if govs:
        out.append({
            "id": "cpu.scaling_governor",
            "title": "CPU scaling governor",
            "description": "Frequency scaling policy (driver: %s). With amd-pstate-epp, 'powersave' plus the energy-performance preference is the intended pairing; 'performance' pins the EPP to maximum." % (read(base + "/scaling_driver") or "unknown"),
            "group": "aggressive", "category": cat, "risk": "medium",
            "generated": True,
            "default": read(base + "/scaling_governor") or "—",
            "recommended": "powersave (amd-pstate-epp) — see EPP below",
            "choices": govs,
            "live": {"type": "procfile", "path": base + "/scaling_governor"},
            "persistent": {"type": "none"},
            "edit": {"class": "sysfs"},
            "verify": "cat %s/scaling_governor" % base,
            "rollback": "Echo the previous governor back; runtime-only (cpu0 shown; tools like cpupower set all cores)."
        })
    prefs = (read(base + "/energy_performance_available_preferences") or "").split()
    if prefs:
        out.append({
            "id": "cpu.energy_performance_preference",
            "title": "CPU energy/performance preference (EPP)",
            "description": "amd-pstate-epp hint balancing power draw against responsiveness for the whole package (cpu0 shown).",
            "group": "aggressive", "category": cat, "risk": "low",
            "generated": True,
            "source": "kernel amd-pstate admin-guide",
            "default": read(base + "/energy_performance_preference") or "—",
            "recommended": "balance_performance (desktop). Note: on Zen2 (3960X) amd-pstate uses the slower shared-memory CPPC path — the firmware, not the governor, picks frequency from min/max + this EPP hint; effect is real but less studied than on MSR-based Zen3+",
            "choices": prefs,
            "live": {"type": "procfile", "path": base + "/energy_performance_preference"},
            "persistent": {"type": "none"},
            "edit": {"class": "sysfs"},
            "verify": "cat %s/energy_performance_preference" % base,
            "rollback": "Echo the previous preference back; runtime-only."
        })
    if read(base + "/boost") is not None:
        out.append({
            "id": "cpu.boost",
            "title": "CPU frequency boost",
            "description": "Whether cores may exceed base clocks. Disabling trades peak performance for lower heat and steadier clocks.",
            "group": "aggressive", "category": cat, "risk": "low",
            "generated": True,
            "default": read(base + "/boost") or "1",
            "recommended": "1 (enabled)",
            "choices": ["0", "1"],
            "live": {"type": "procfile", "path": base + "/boost"},
            "persistent": {"type": "none"},
            "edit": {"class": "sysfs"},
            "verify": "cat %s/boost" % base,
            "rollback": "echo 1 back; runtime-only."
        })
    return out


def net_entries():
    out = []
    for iface in sorted(os.listdir("/sys/class/net")):
        base = "/sys/class/net/" + iface
        if not os.path.exists(base + "/device"):
            continue  # physical NICs only; virtual ifaces churn constantly
        cat = "device - net - " + iface
        out.append({
            "id": "net.%s.mtu" % iface,
            "title": "%s MTU" % iface,
            "description": "Maximum transmission unit for physical NIC %s. 1500 is standard Ethernet; jumbo frames need every hop to agree." % iface,
            "group": "aggressive", "category": cat, "risk": "medium",
            "generated": True,
            "default": "1500",
            "recommended": "1500 unless the whole path is jumbo-clean",
            "range": {"min": 576, "max": 9216},
            "live": {"type": "procfile", "path": base + "/mtu"},
            "persistent": {"type": "none"},
            "edit": {"class": "sysfs"},
            "verify": "cat %s/mtu" % base,
            "rollback": "Echo 1500 back (or reapply the NetworkManager profile)."
        })
        out.append({
            "id": "net.%s.speed" % iface,
            "title": "%s link speed" % iface,
            "description": "Negotiated link speed (Mb/s) for %s." % iface,
            "group": "info", "category": cat, "risk": "none",
            "generated": True,
            "default": "—",
            "recommended": "highest the link negotiates",
            "live": {"type": "procfile", "path": base + "/speed"},
            "persistent": {"type": "none"},
            "verify": "cat %s/speed" % base,
            "rollback": "n/a (informational)"
        })
    return out


def main():
    write = "--write" in sys.argv
    generated = block_entries() + cpufreq_entries() + net_entries()

    with open(SCHEMAS) as f:
        doc = json.load(f)
    kept = [s for s in doc["settings"] if not s.get("generated")]
    doc["settings"] = kept + generated

    print("hand-written entries kept: %d, device entries generated: %d" % (len(kept), len(generated)))
    for s in generated:
        print("  %-34s %s" % (s["id"], s["category"]))
    if write:
        with open(SCHEMAS, "w") as f:
            json.dump(doc, f, indent=4)
            f.write("\n")
        print("wrote %s" % os.path.normpath(SCHEMAS))
    else:
        print("(dry run — pass --write to update schemas.json)")


if __name__ == "__main__":
    main()
