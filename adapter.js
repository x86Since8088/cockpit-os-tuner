/*
 * adapter.js — backend abstraction for cockpit-tuner.
 *
 * Every interaction with the system goes through TunerBackend, which has two
 * implementations chosen at load time:
 *
 *   - CockpitBackend: real reads via cockpit.js (cockpit-bridge). Read-only by
 *     design: it never runs with superuser and the only writes it performs are
 *     snapshot JSON files under the user's own ~/.local/share/cockpit-tuner/.
 *
 *   - MockBackend: used automatically when cockpit.js is absent (page opened
 *     outside the Cockpit shell). Serves canned data and stores snapshots in
 *     localStorage, so the whole UI can be exercised in a plain browser.
 */

(function () {
    "use strict";

    var HISTORY_SUBDIR = ".local/share/cockpit-tuner/history";

    /* ---------------- Cockpit backend ---------------- */

    function CockpitBackend() {
        this.isMock = false;
        this._homedir = null;
    }

    CockpitBackend.prototype.init = function () {
        var self = this;
        return cockpit.user().then(function (user) {
            self._homedir = user.home || "/root";
        });
    };

    CockpitBackend.prototype.readFile = function (path) {
        return cockpit.file(path).read().then(function (content) {
            return content; /* null when the file does not exist */
        }, function () {
            return null;
        });
    };

    /* argv: array. Resolves stdout string, or null on any failure. */
    CockpitBackend.prototype.spawn = function (argv) {
        return cockpit.spawn(argv, { err: "message", environ: ["LC_ALL=C"] })
            .then(function (out) { return out; })
            .catch(function () { return null; });
    };

    CockpitBackend.prototype._historyDir = function () {
        return this._homedir + "/" + HISTORY_SUBDIR;
    };

    CockpitBackend.prototype.listSnapshots = function () {
        var dir = this._historyDir();
        return this.spawn(["sh", "-c", "ls -1 '" + dir + "' 2>/dev/null || true"])
            .then(function (out) {
                if (!out)
                    return [];
                return out.trim().split("\n").filter(function (n) {
                    return n.endsWith(".json");
                }).sort().reverse();
            });
    };

    CockpitBackend.prototype.readSnapshot = function (name) {
        return this.readFile(this._historyDir() + "/" + name).then(function (content) {
            if (!content)
                return null;
            try { return JSON.parse(content); } catch (e) { return null; }
        });
    };

    CockpitBackend.prototype.saveSnapshot = function (name, data) {
        var self = this;
        var dir = this._historyDir();
        return this.spawn(["mkdir", "-p", dir]).then(function () {
            return cockpit.file(dir + "/" + name).replace(JSON.stringify(data, null, 2));
        });
    };

    /* ---------------- Mock backend ---------------- */

    function MockBackend() {
        this.isMock = true;

        this._files = {
            "/proc/sys/vm/swappiness": "60\n",
            "/proc/sys/vm/max_map_count": "1048576\n",
            "/proc/sys/vm/overcommit_memory": "0\n",
            "/proc/sys/vm/min_free_kbytes": "67584\n",
            "/proc/sys/fs/inotify/max_user_watches": "65536\n",
            "/proc/sys/fs/inotify/max_user_instances": "128\n",
            "/proc/sys/kernel/core_pattern": "|/usr/share/apport/apport %p %s %c %d %P %E\n",
            "/proc/sys/kernel/sched_bore": null,
            "/sys/kernel/mm/transparent_hugepage/enabled": "always [madvise] never\n",
            "/sys/kernel/mm/lru_gen/enabled": "0x0007\n",
            "/proc/cmdline": "BOOT_IMAGE=/boot/vmlinuz-7.0.0-30-generic root=UUID=mock ro quiet splash\n",
            "/etc/default/grub": "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash\"\nGRUB_CMDLINE_LINUX=\"\"\n",
            "/etc/systemd/oomd.conf": "[OOM]\n#SwapUsedLimit=90%\n#DefaultMemoryPressureLimit=60%\n#DefaultMemoryPressureDurationSec=30s\n",
            "/etc/systemd/system.conf": "[Manager]\n#DefaultLimitNOFILE=1024:524288\n"
        };

        this._commands = {
            "sysctl-grep": "/usr/lib/sysctl.d/99-protect-links.conf:fs.protected_symlinks = 1\n",
            "uname-r": "7.0.0-30-generic\n",
            "uname-v": "PREEMPT_DYNAMIC\n",
            "gpu-driver": "nouveau\n",
            "swap-devices": "/swap.img file 8G 0B -1\n",
            "oomd-active": "active\n",
            "ulimit-n": "524288\n",
            "config-hz": "CONFIG_HZ=1000\n"
        };
    }

    MockBackend.prototype.init = function () {
        return Promise.resolve();
    };

    MockBackend.prototype.readFile = function (path) {
        var v = this._files[path];
        return Promise.resolve(v === undefined ? null : v);
    };

    MockBackend.prototype.spawn = function (argv) {
        /* Mock keys on a stable tag we smuggle in via a leading "echo" marker
         * is fragile; instead match on the joined command line. */
        var line = argv.join(" ");
        var out = null;
        if (line.indexOf("grep -rHsE") !== -1 && line.indexOf("sysctl") !== -1)
            out = this._commands["sysctl-grep"];
        else if (line.indexOf("CONFIG_HZ=") !== -1)
            out = this._commands["config-hz"];
        else if (line.indexOf("uname -r") !== -1)
            out = this._commands["uname-r"];
        else if (line.indexOf("uname -v") !== -1)
            out = this._commands["uname-v"];
        else if (line.indexOf("lspci") !== -1)
            out = this._commands["gpu-driver"];
        else if (line.indexOf("swapon") !== -1)
            out = this._commands["swap-devices"];
        else if (line.indexOf("is-active systemd-oomd") !== -1)
            out = this._commands["oomd-active"];
        else if (line.indexOf("ulimit -n") !== -1)
            out = this._commands["ulimit-n"];
        else if (line.indexOf("mkdir") !== -1)
            out = "";
        return Promise.resolve(out);
    };

    MockBackend.prototype.listSnapshots = function () {
        var names = [];
        for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            if (k && k.indexOf("tuner-snapshot:") === 0)
                names.push(k.slice("tuner-snapshot:".length));
        }
        return Promise.resolve(names.sort().reverse());
    };

    MockBackend.prototype.readSnapshot = function (name) {
        try {
            var raw = localStorage.getItem("tuner-snapshot:" + name);
            return Promise.resolve(raw ? JSON.parse(raw) : null);
        } catch (e) {
            return Promise.resolve(null);
        }
    };

    MockBackend.prototype.saveSnapshot = function (name, data) {
        try {
            localStorage.setItem("tuner-snapshot:" + name, JSON.stringify(data));
        } catch (e) { /* storage may be unavailable; snapshot silently lost in mock */ }
        return Promise.resolve();
    };

    /* ---------------- selection ---------------- */

    window.TunerBackend = (typeof cockpit !== "undefined" && cockpit.spawn)
        ? new CockpitBackend()
        : new MockBackend();
})();
