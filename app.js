/*
 * app.js — cockpit-tuner main application.
 * Read-only comparison matrix: profile recommendation vs live vs persistent
 * vs historical snapshot, driven entirely by schemas.json / profiles.json.
 */

(function () {
    "use strict";

    var backend = window.TunerBackend;

    var state = {
        settings: [],          /* from schemas.json */
        profiles: [],          /* from profiles.json */
        values: {},            /* id -> { live, liveCmp, persistent, persistentCmp, persistentDetail } */
        snapshots: [],         /* names */
        snapshot: null,        /* loaded snapshot object or null */
        group: "all",
        profileId: null,
        category: "",
        search: ""
    };

    var SYSCTL_DIRS = ["/etc/sysctl.conf", "/etc/sysctl.d/", "/run/sysctl.d/", "/usr/lib/sysctl.d/"];

    /* ---------------- helpers ---------------- */

    function esc(s) {
        return String(s == null ? "" : s)
            .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;");
    }

    function $(id) { return document.getElementById(id); }

    function setStatus(msg) { $("status-line").textContent = msg || ""; }

    function fetchJSON(path) {
        return fetch(path).then(function (r) {
            if (!r.ok)
                throw new Error(path + ": HTTP " + r.status);
            return r.json();
        });
    }

    /* ---------------- value resolution ---------------- */

    function resolveLive(setting) {
        var src = setting.live || { type: "none" };
        if (src.type === "none")
            return Promise.resolve(null);

        if (src.type === "procfile" || src.type === "procfile-bracket") {
            return backend.readFile(src.path).then(function (content) {
                if (content == null)
                    return src.emptyAs || null;
                var v = content.trim();
                if (src.type === "procfile-bracket") {
                    var m = v.match(/\[([^\]]+)\]/);
                    v = m ? m[1] : v;
                }
                return v === "" ? (src.emptyAs || null) : v;
            });
        }

        if (src.type === "command") {
            return backend.spawn(src.argv).then(function (out) {
                var v = (out || "").trim();
                return v === "" ? (src.emptyAs || null) : v;
            });
        }

        if (src.type === "file-regex")
            return resolveFileRegex(src);

        return Promise.resolve(null);
    }

    function resolveFileRegex(src) {
        return backend.readFile(src.path).then(function (content) {
            if (content == null)
                return null;
            var re = new RegExp(src.regex, "m");
            var m = content.match(re);
            return m ? (m[1] !== undefined ? m[1] : m[0]).trim() : null;
        });
    }

    /* Batched: one grep for every sysctl-persisted key. Returns id -> {value, file}. */
    function resolveSysctlPersistent(settings) {
        var keys = settings
            .filter(function (s) { return s.persistent && s.persistent.type === "sysctl"; })
            .map(function (s) { return s.persistent.key; });
        if (!keys.length)
            return Promise.resolve({});

        var pattern = "^\\s*(" + keys.map(function (k) {
            return k.replace(/\./g, "\\.");
        }).join("|") + ")\\s*=";
        var cmd = "grep -rHsE '" + pattern + "' " + SYSCTL_DIRS.join(" ") + " 2>/dev/null || true";

        return backend.spawn(["sh", "-c", cmd]).then(function (out) {
            var byKey = {};
            (out || "").trim().split("\n").forEach(function (line) {
                /* file:key = value */
                var m = line.match(/^([^:]+):\s*([^=\s]+)\s*=\s*(.*)$/);
                if (!m)
                    return;
                var entry = { file: m[1], key: m[2], value: m[3].trim() };
                if (!byKey[entry.key])
                    byKey[entry.key] = [];
                byKey[entry.key].push(entry);
            });

            /* sysctl.d precedence: files sorted by basename; same basename -> /etc wins */
            var result = {};
            Object.keys(byKey).forEach(function (key) {
                var entries = byKey[key].sort(function (a, b) {
                    var ba = a.file.split("/").pop(), bb = b.file.split("/").pop();
                    if (ba !== bb)
                        return ba < bb ? -1 : 1;
                    return (a.file.indexOf("/etc/") === 0 ? 1 : 0) - (b.file.indexOf("/etc/") === 0 ? 1 : 0);
                });
                var winner = entries[entries.length - 1];
                result[key] = { value: winner.value, file: winner.file, all: entries };
            });
            return result;
        });
    }

    function resolvePersistent(setting, sysctlMap) {
        var src = setting.persistent || { type: "none" };
        if (src.type === "none")
            return Promise.resolve({ display: null, cmp: null });

        if (src.type === "sysctl") {
            var hit = sysctlMap[src.key];
            if (!hit)
                return Promise.resolve({ display: "not set", cmp: null });
            return Promise.resolve({
                display: hit.value + "  ·  " + hit.file.split("/").pop(),
                cmp: hit.value,
                detail: hit.all.map(function (e) { return e.file + " = " + e.value; }).join("\n")
            });
        }

        if (src.type === "file-regex") {
            return resolveFileRegex(src).then(function (v) {
                return { display: v == null ? "not set" : v, cmp: v };
            });
        }

        if (src.type === "command") {
            return backend.spawn(src.argv).then(function (out) {
                var v = (out || "").trim();
                return { display: v === "" ? "not set" : v, cmp: v === "" ? null : v };
            });
        }

        return Promise.resolve({ display: null, cmp: null });
    }

    function loadAllValues() {
        setStatus("Reading live and persistent values…");
        return resolveSysctlPersistent(state.settings).then(function (sysctlMap) {
            var jobs = state.settings.map(function (s) {
                return Promise.all([resolveLive(s), resolvePersistent(s, sysctlMap)])
                    .then(function (res) {
                        state.values[s.id] = {
                            live: res[0] == null ? "—" : res[0],
                            liveCmp: res[0],
                            persistent: res[1].display == null ? "—" : res[1].display,
                            persistentCmp: res[1].cmp,
                            persistentDetail: res[1].detail || null
                        };
                    });
            });
            return Promise.all(jobs);
        }).then(function () {
            setStatus("Updated " + new Date().toLocaleTimeString());
        });
    }

    /* ---------------- snapshots ---------------- */

    function refreshSnapshotList() {
        return backend.listSnapshots().then(function (names) {
            state.snapshots = names;
            var sel = $("snapshot-select");
            var current = sel.value;
            sel.innerHTML = "<option value=''>— none —</option>" + names.map(function (n) {
                return "<option value='" + esc(n) + "'>" + esc(n.replace(/^snapshot-|\.json$/g, "")) + "</option>";
            }).join("");
            if (names.indexOf(current) !== -1)
                sel.value = current;
        });
    }

    function takeSnapshot() {
        var stamp = new Date().toISOString().replace(/[:]/g, "-").replace(/\..*$/, "");
        var name = "snapshot-" + stamp + ".json";
        var data = { name: name, timestamp: new Date().toISOString(), values: {} };
        state.settings.forEach(function (s) {
            var v = state.values[s.id] || {};
            data.values[s.id] = { live: v.liveCmp, persistent: v.persistentCmp };
        });
        setStatus("Saving snapshot…");
        backend.saveSnapshot(name, data).then(function () {
            return refreshSnapshotList();
        }).then(function () {
            $("snapshot-select").value = name;
            return loadSnapshot(name);
        });
    }

    function loadSnapshot(name) {
        if (!name) {
            state.snapshot = null;
            render();
            return Promise.resolve();
        }
        return backend.readSnapshot(name).then(function (data) {
            state.snapshot = data;
            setStatus(data ? "Comparing against " + name : "Could not read snapshot " + name);
            render();
        });
    }

    /* ---------------- rendering ---------------- */

    function activeProfile() {
        for (var i = 0; i < state.profiles.length; i++)
            if (state.profiles[i].id === state.profileId)
                return state.profiles[i];
        return null;
    }

    function visibleSettings() {
        var q = state.search.toLowerCase();
        return state.settings.filter(function (s) {
            if (state.group !== "all" && s.group !== state.group)
                return false;
            if (state.category && s.category !== state.category)
                return false;
            if (q && (s.id + " " + s.title + " " + s.description).toLowerCase().indexOf(q) === -1)
                return false;
            return true;
        });
    }

    function render() {
        var profile = activeProfile();
        var body = $("settings-body");
        var rows = visibleSettings().map(function (s) {
            var v = state.values[s.id] || { live: "…", persistent: "…" };
            var profVal = profile && profile.values ? profile.values[s.id] : undefined;
            var snapVal = state.snapshot && state.snapshot.values ? state.snapshot.values[s.id] : undefined;

            var profClass = "", persClass = "", snapClass = "", liveClass = "";
            if (profVal !== undefined && v.liveCmp != null) {
                if (String(profVal).trim() === String(v.liveCmp).trim()) {
                    profClass = "cell-ok";
                    liveClass = "cell-ok";
                } else {
                    profClass = "cell-mismatch";
                }
            }
            if (v.persistentCmp != null && v.liveCmp != null &&
                String(v.persistentCmp).trim() !== String(v.liveCmp).trim())
                persClass = "cell-drift";
            if (snapVal && snapVal.live != null && v.liveCmp != null &&
                String(snapVal.live).trim() !== String(v.liveCmp).trim())
                snapClass = "cell-changed";

            return "<tr data-id='" + esc(s.id) + "'>" +
                "<td class='cell-name'><span class='setting-title'>" + esc(s.title) + "</span>" +
                    "<span class='setting-cat'>" + esc(s.category) + "</span></td>" +
                "<td><span class='badge badge-" + esc(s.group) + "'>" + esc(s.group) + "</span>" +
                    (s.risk && s.risk !== "none" ? " <span class='risk risk-" + esc(s.risk) + "'>" + esc(s.risk) + "</span>" : "") + "</td>" +
                "<td class='" + profClass + " col-profile'>" + (profVal === undefined ? "—" : esc(profVal)) + "</td>" +
                "<td class='" + liveClass + " cell-mono'>" + esc(v.live) + "</td>" +
                "<td class='" + persClass + " cell-mono'>" + esc(v.persistent) + "</td>" +
                "<td class='" + snapClass + " cell-mono col-snapshot'>" +
                    (snapVal === undefined || !state.snapshot ? "—" : esc(snapVal.live == null ? "—" : snapVal.live)) + "</td>" +
                "</tr>";
        });
        body.innerHTML = rows.join("") ||
            "<tr><td colspan='6' class='empty'>No settings match the current filters.</td></tr>";
    }

    function showDetail(id) {
        var s = state.settings.filter(function (x) { return x.id === id; })[0];
        if (!s)
            return;
        var v = state.values[id] || {};
        var html = "<h2>" + esc(s.title) + "</h2>" +
            "<p>" + esc(s.description) + "</p>" +
            "<dl>" +
            "<dt>Group</dt><dd>" + esc(s.group) + (s.risk ? " (risk: " + esc(s.risk) + ")" : "") + "</dd>" +
            "<dt>Live value</dt><dd class='cell-mono'>" + esc(v.live || "—") + "</dd>" +
            "<dt>Persistent</dt><dd class='cell-mono'>" + esc(v.persistent || "—") +
                (v.persistentDetail ? "<pre>" + esc(v.persistentDetail) + "</pre>" : "") + "</dd>" +
            "<dt>Verify</dt><dd><code>" + esc(s.verify || "—") + "</code></dd>" +
            "<dt>Rollback</dt><dd>" + esc(s.rollback || "—") + "</dd>" +
            "</dl>";
        $("detail-content").innerHTML = html;
        $("detail-panel").hidden = false;
    }

    /* ---------------- wiring ---------------- */

    function populateControls() {
        var psel = $("profile-select");
        psel.innerHTML = state.profiles.map(function (p) {
            return "<option value='" + esc(p.id) + "'>" + esc(p.title) + "</option>";
        }).join("");
        state.profileId = state.profiles.length ? state.profiles[0].id : null;

        var cats = {};
        state.settings.forEach(function (s) { cats[s.category] = true; });
        $("category-select").innerHTML = "<option value=''>all</option>" +
            Object.keys(cats).sort().map(function (c) {
                return "<option value='" + esc(c) + "'>" + esc(c) + "</option>";
            }).join("");
    }

    function bindEvents() {
        $("group-tabs").addEventListener("click", function (ev) {
            var btn = ev.target.closest(".tab");
            if (!btn)
                return;
            state.group = btn.dataset.group;
            document.querySelectorAll(".tab").forEach(function (t) { t.classList.remove("active"); });
            btn.classList.add("active");
            render();
        });
        $("profile-select").addEventListener("change", function () {
            state.profileId = this.value;
            render();
        });
        $("snapshot-select").addEventListener("change", function () {
            loadSnapshot(this.value);
        });
        $("category-select").addEventListener("change", function () {
            state.category = this.value;
            render();
        });
        $("search-box").addEventListener("input", function () {
            state.search = this.value;
            render();
        });
        $("btn-refresh").addEventListener("click", function () {
            loadAllValues().then(render);
        });
        $("btn-snapshot").addEventListener("click", takeSnapshot);
        $("settings-body").addEventListener("click", function (ev) {
            var tr = ev.target.closest("tr[data-id]");
            if (tr)
                showDetail(tr.dataset.id);
        });
        $("detail-close").addEventListener("click", function () {
            $("detail-panel").hidden = true;
        });
    }

    function init() {
        if (backend.isMock)
            $("mode-badge").hidden = false;

        Promise.all([fetchJSON("schemas.json"), fetchJSON("profiles.json"), backend.init()])
            .then(function (res) {
                state.settings = res[0].settings || [];
                state.profiles = res[1].profiles || [];
                populateControls();
                bindEvents();
                render();
                return Promise.all([loadAllValues(), refreshSnapshotList()]);
            })
            .then(render)
            .catch(function (err) {
                setStatus("Failed to initialize: " + err.message);
            });
    }

    document.addEventListener("DOMContentLoaded", init);
})();
