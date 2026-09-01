/*
 * app.js — cockpit-tuner main application.
 * Comparison matrix (profile vs live vs persistent vs snapshot) driven by
 * schemas.json / profiles.json, plus an ADMIN-GATED edit path: settings whose
 * schema carries an `edit` descriptor can be changed from the detail panel,
 * and every apply is journaled to a root-owned undo log so changes can be
 * rolled back if system stability is impacted.
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
        search: "",
        admin: false,          /* cockpit administrative access active */
        undo: [],              /* undo journal entries (newest last) */
        detailId: null         /* setting id currently open in the panel */
    };

    var DROPIN = "/etc/sysctl.d/95-cockpit-tuner.conf";

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

    function rangeText(s) {
        if (s.choices)
            return s.choices.join(" | ");
        if (s.range)
            return s.range.min + " – " + s.range.max;
        return null;
    }

    function showDetail(id) {
        var s = state.settings.filter(function (x) { return x.id === id; })[0];
        if (!s)
            return;
        state.detailId = id;
        var v = state.values[id] || {};
        var html = "<h2>" + esc(s.title) + "</h2>" +
            "<p>" + esc(s.description) + "</p>" +
            "<dl>" +
            "<dt>Group</dt><dd>" + esc(s.group) + (s.risk ? " (risk: " + esc(s.risk) + ")" : "") + "</dd>" +
            "<dt>Default</dt><dd class='cell-mono'>" + esc(s.default || "—") + "</dd>" +
            "<dt>Recommended</dt><dd class='cell-mono'>" + esc(s.recommended || "—") + "</dd>" +
            (rangeText(s) ? "<dt>Allowed</dt><dd class='cell-mono'>" + esc(rangeText(s)) + "</dd>" : "") +
            "<dt>Live value</dt><dd class='cell-mono'>" + esc(v.live || "—") + "</dd>" +
            "<dt>Persistent</dt><dd class='cell-mono'>" + esc(v.persistent || "—") +
                (v.persistentDetail ? "<pre>" + esc(v.persistentDetail) + "</pre>" : "") + "</dd>" +
            "<dt>Verify</dt><dd><code>" + esc(s.verify || "—") + "</code></dd>" +
            "<dt>Rollback</dt><dd>" + esc(s.rollback || "—") + "</dd>" +
            "</dl>";

        if (s.edit) {
            if (state.admin) {
                var isSysctl = s.edit.class === "sysctl";
                html += "<div class='edit-box'>" +
                    "<h3>Edit setting</h3>" +
                    "<div class='edit-row'>" +
                    (s.choices
                        ? "<select id='edit-value' class='edit-input'>" + s.choices.map(function (c) {
                            return "<option value='" + esc(c) + "'" +
                                (String(v.liveCmp) === c ? " selected" : "") + ">" + esc(c) + "</option>";
                          }).join("") + "</select>"
                        : "<input id='edit-value' class='edit-input' type='" + (s.range ? "number" : "text") + "'" +
                          (s.range ? " min='" + s.range.min + "' max='" + s.range.max + "'" : "") +
                          " value='" + esc(v.liveCmp == null ? "" : v.liveCmp) + "'>") +
                    (isSysctl
                        ? "<label class='edit-persist'><input type='checkbox' id='edit-persist'> persist in " +
                          "<code>" + esc(DROPIN.split("/").pop()) + "</code></label>"
                        : "<span class='edit-persist' style='color:var(--muted)'>runtime-only (sysfs)</span>") +
                    "<button id='edit-apply' class='btn btn-primary'>Apply</button>" +
                    "</div>" +
                    "<pre id='edit-preview' class='edit-preview'></pre>" +
                    "<div id='edit-msg' class='edit-msg'></div>" +
                    "<p class='edit-note'>Every apply is added to the undo history, so it can be " +
                    "rolled back if system stability is impacted.</p>" +
                    "</div>";
            } else {
                html += "<div class='edit-box edit-locked'>Editable with administrative access — " +
                        "turn it on in the Cockpit header to change this setting.</div>";
            }
        }

        $("detail-content").innerHTML = html;
        $("detail-panel").hidden = false;

        if (s.edit && state.admin) {
            var input = $("edit-value");
            var updatePreview = function () {
                $("edit-preview").textContent = buildApply(s, input.value,
                    $("edit-persist") && $("edit-persist").checked).preview;
            };
            input.addEventListener("input", updatePreview);
            input.addEventListener("change", updatePreview);
            if ($("edit-persist"))
                $("edit-persist").addEventListener("change", updatePreview);
            $("edit-apply").addEventListener("click", function () { applySetting(s); });
            updatePreview();
        }
    }

    /* ---------------- admin apply + undo ---------------- */

    var SAFE_VALUE = /^[A-Za-z0-9x+._-]+$/;

    function buildApply(s, value, persist) {
        var cmds = [];
        var preview = [];
        if (s.edit.class === "sysctl") {
            var key = s.persistent.key;
            cmds.push(["sysctl", "-w", key + "=" + value]);
            preview.push("sysctl -w " + key + "=" + value);
            if (persist)
                preview.push("update " + DROPIN + " (" + key + " = " + value + ")");
        } else {
            var path = s.live.path;
            cmds.push(["sh", "-c", "printf %s '" + value + "' > '" + path + "'"]);
            preview.push("printf %s '" + value + "' > " + path);
        }
        return { cmds: cmds, preview: preview.join("\n") };
    }

    function validateEdit(s, value) {
        if (value === "" || value == null)
            return "A value is required.";
        if (!SAFE_VALUE.test(value))
            return "Only letters, digits and x + . _ - are allowed.";
        if (s.choices && s.choices.indexOf(value) === -1)
            return "Must be one of: " + s.choices.join(", ");
        if (s.range) {
            var n = Number(value);
            if (!isFinite(n) || Math.floor(n) !== n)
                return "Must be a whole number.";
            if (n < s.range.min || n > s.range.max)
                return "Must be between " + s.range.min + " and " + s.range.max + ".";
        }
        return null;
    }

    function editMsg(text, ok) {
        var el = $("edit-msg");
        if (el) {
            el.textContent = text;
            el.className = "edit-msg " + (ok ? "edit-ok" : "edit-err");
        }
    }

    function applySetting(s) {
        var value = String($("edit-value").value).trim();
        var persist = !!($("edit-persist") && $("edit-persist").checked);
        var err = validateEdit(s, value);
        if (err) {
            editMsg(err, false);
            return;
        }
        var prevLive = state.values[s.id] ? state.values[s.id].liveCmp : null;
        var built = buildApply(s, value, persist);
        $("edit-apply").disabled = true;
        editMsg("Applying…", true);

        var persistPrev = null;
        var chain = Promise.resolve();
        if (persist) {
            chain = chain.then(function () {
                return backend.readFile(DROPIN).then(function (content) {
                    persistPrev = content; /* null when absent */
                });
            });
        }
        built.cmds.forEach(function (argv) {
            chain = chain.then(function () { return backend.rootRun(argv); });
        });
        if (persist) {
            chain = chain.then(function () {
                var key = s.persistent.key;
                var lines = (persistPrev || "# Managed by cockpit-tuner — safe to delete.\n")
                    .split("\n").filter(function (l) {
                        return l.trim() !== "" && l.indexOf(key + " ") !== 0 && l.indexOf(key + "=") !== 0;
                    });
                lines.push(key + " = " + value);
                return backend.rootWriteFile(DROPIN, lines.join("\n") + "\n");
            });
        }
        chain.then(function () {
            var entry = {
                kind: "apply",
                id: String(Date.now()) + "-" + s.id,
                ts: new Date().toISOString(),
                setting: s.id,
                title: s.title,
                cls: s.edit.class,
                key: s.edit.class === "sysctl" ? s.persistent.key : s.live.path,
                prev: prevLive,
                next: value,
                persist: persist ? { file: DROPIN, prevContent: persistPrev } : null
            };
            return backend.appendUndo(entry);
        }).then(function () {
            return Promise.all([loadAllValues(), loadUndo()]);
        }).then(function () {
            render();
            showDetail(s.id);
            editMsg("Applied. Added to undo history.", true);
            setStatus("Applied " + s.id + " = " + value);
        }).catch(function (e) {
            $("edit-apply").disabled = false;
            editMsg("Failed: " + (e && e.message ? e.message : e), false);
        });
    }

    function activeUndoEntries() {
        var undone = {};
        state.undo.forEach(function (e) {
            if (e.kind === "undo" && e.undoOf)
                undone[e.undoOf] = true;
        });
        return state.undo.filter(function (e) {
            return e.kind === "apply";
        }).map(function (e) {
            return { entry: e, undone: !!undone[e.id] };
        }).reverse();
    }

    function loadUndo() {
        if (!backend.readUndo)
            return Promise.resolve();
        return backend.readUndo().then(function (entries) {
            state.undo = entries;
            var n = activeUndoEntries().filter(function (x) { return !x.undone; }).length;
            var btn = $("btn-undo");
            if (btn)
                btn.textContent = "Undo history" + (n ? " (" + n + ")" : "");
        }).catch(function () { /* not admin: journal unreadable, leave empty */ });
    }

    function undoEntry(e) {
        var chain = Promise.resolve();
        if (e.prev != null) {
            if (e.cls === "sysctl")
                chain = chain.then(function () {
                    return backend.rootRun(["sysctl", "-w", e.key + "=" + e.prev]);
                });
            else
                chain = chain.then(function () {
                    return backend.rootRun(["sh", "-c", "printf %s '" + e.prev + "' > '" + e.key + "'"]);
                });
        }
        if (e.persist)
            chain = chain.then(function () {
                return backend.rootWriteFile(e.persist.file,
                    e.persist.prevContent == null
                        ? "# Managed by cockpit-tuner — safe to delete.\n"
                        : e.persist.prevContent);
            });
        chain.then(function () {
            return backend.appendUndo({
                kind: "undo", undoOf: e.id, ts: new Date().toISOString(),
                setting: e.setting, restored: e.prev
            });
        }).then(function () {
            return Promise.all([loadAllValues(), loadUndo()]);
        }).then(function () {
            render();
            showUndoPanel();
            setStatus("Undid " + e.setting + " (restored " + (e.prev == null ? "previous state" : e.prev) + ")");
        }).catch(function (err) {
            setStatus("Undo failed: " + (err && err.message ? err.message : err));
        });
    }

    function showUndoPanel() {
        state.detailId = null;
        var rows = activeUndoEntries();
        var html = "<h2>Undo history</h2>" +
            "<p class='edit-note'>Every applied edit lands here (journal: <code>/var/lib/cockpit-tuner/undo.jsonl</code>, " +
            "kept across reboots). Undo restores the previous value — use it if system stability is impacted.</p>";
        if (!state.admin)
            html += "<div class='edit-box edit-locked'>Reading and undoing requires administrative access.</div>";
        else if (!rows.length)
            html += "<p class='edit-note'>No edits recorded yet.</p>";
        else
            html += "<ul class='undo-list'>" + rows.map(function (r) {
                var e = r.entry;
                return "<li class='undo-entry" + (r.undone ? " undone" : "") + "'>" +
                    "<div><strong>" + esc(e.title || e.setting) + "</strong> " +
                    "<span class='cell-mono'>" + esc(e.prev == null ? "unset" : e.prev) + " → " + esc(e.next) + "</span>" +
                    (e.persist ? " <span class='badge badge-info'>persisted</span>" : "") +
                    (r.undone ? " <span class='badge'>undone</span>" : "") +
                    "</div>" +
                    "<div class='undo-meta'>" + esc(e.ts.replace("T", " ").slice(0, 19)) + "</div>" +
                    (r.undone ? "" :
                        "<button class='btn sm-undo' data-undo='" + esc(e.id) + "'>Undo</button>") +
                    "</li>";
            }).join("") + "</ul>";
        $("detail-content").innerHTML = html;
        $("detail-panel").hidden = false;
        Array.prototype.forEach.call(
            $("detail-content").querySelectorAll("button[data-undo]"),
            function (btn) {
                btn.addEventListener("click", function () {
                    var e = state.undo.filter(function (x) { return x.id === btn.dataset.undo; })[0];
                    if (e)
                        undoEntry(e);
                });
            });
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
        $("btn-undo").addEventListener("click", showUndoPanel);
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
        if (backend.isMock) {
            $("mode-badge").hidden = false;
            state.admin = true; /* mock exercises the full admin UI */
        } else {
            try {
                var perm = cockpit.permission({ admin: true });
                var syncAdmin = function () {
                    var was = state.admin;
                    state.admin = !!perm.allowed;
                    if (was !== state.admin) {
                        loadUndo();
                        render();
                        if (state.detailId)
                            showDetail(state.detailId);
                    }
                };
                perm.addEventListener("changed", syncAdmin);
                state.admin = !!perm.allowed;
            } catch (e) {
                state.admin = false;
            }
        }

        Promise.all([fetchJSON("schemas.json"), fetchJSON("profiles.json"), backend.init()])
            .then(function (res) {
                state.settings = res[0].settings || [];
                state.profiles = res[1].profiles || [];
                populateControls();
                bindEvents();
                render();
                return Promise.all([loadAllValues(), refreshSnapshotList(), loadUndo()]);
            })
            .then(render)
            .catch(function (err) {
                setStatus("Failed to initialize: " + err.message);
            });
    }

    document.addEventListener("DOMContentLoaded", init);
})();
