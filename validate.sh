#!/usr/bin/env bash
#
# validate.sh - the standing gate for cockpit-tuner.
#
# Cheap, and every check is an invariant rather than a one-off: syntax, JSON
# validity, and the deployment bans from docs/DEPLOY-CONTRACT.md (which lives in
# cockpit-secrets and governs this project too). deploy.sh refuses to copy a
# payload that does not pass this.
#
# PROGRESSIVE: a check whose subject does not exist yet is skipped, not failed.
# Exit 0 = pass.
#
# There is no `set -x` in this tree: the /srv/jobs runner's log is group-readable.
#
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

rc=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; rc=1; }
skip() { printf '  \033[2mskip\033[0m  %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

# The dev root, split so that this file's own mention of it cannot match itself
# and turn every check below into a permanent self-inflicted failure.
DEV_ROOT_PAT="/srv/smb/share/sc/ai-orchestrator""-group"

# The declared payload, read from install.sh's manifest block - the same single
# source deploy.sh reads. If this file restated it, the two could disagree, and
# a gate that scans a different list from the one that ships is a gate that
# passes the wrong files.
manifest="$(sed -n '/^# BEGIN-MANIFEST/,/^# END-MANIFEST/p' install.sh)"
if [[ -z "$manifest" ]]; then
    echo "validate.sh: install.sh has no BEGIN-MANIFEST block" >&2; exit 1
fi
eval "$manifest"

# The manifest block is read by THREE parsers: bash's eval here, deploy.ps1's
# line-oriented reader, and this file. Only bash joins a continuation line, so
# a multi-line array assignment silently handed the other two a truncated
# STRING where an array was meant - REQUIRED_ENV came back as 64 characters
# instead of 6 keys, and every check that iterated it quietly did nothing.
# One line per assignment, enforced here so it cannot come back.
if printf '%s\n' "$manifest" | grep -qE '^[A-Z_]+=\([^)]*$'; then
    fail "a BEGIN-MANIFEST assignment does not close on one line - the non-bash parsers read it as a truncated string"
    printf '%s\n' "$manifest" | grep -nE '^[A-Z_]+=\([^)]*$' | sed 's/^/        /'
else
    pass "every BEGIN-MANIFEST assignment fits on one line (all three parsers agree)"
fi

# ---------------------------------------------------------------- syntax ----
head_ "Syntax"
if command -v gjs >/dev/null 2>&1; then
    for f in *.js; do
        [[ -e "$f" ]] || continue
        # Parsed inside a wrapper that is never called: parsing happens before
        # execution, so a syntax error still surfaces while cockpit/document/
        # window become harmless formal parameters instead of ReferenceErrors.
        # The header shares a line with the file's first line, so gjs's line
        # numbers are the source file's own.
        tmp="$(mktemp)"
        { printf 'function __never(cockpit, document, window, navigator){'
          cat -- "$f"; printf '\n}\n'; } > "$tmp"
        if gjs "$tmp" 2>/dev/null; then pass "$f parses"
        else fail "$f has a syntax error"; gjs "$tmp" 2>&1 | sed "s#$tmp#$f#g;s/^/        /" | head -4; fi
        rm -f -- "$tmp"
    done
else
    skip "gjs is not installed - the JavaScript syntax gate DID NOT RUN (apt-get install gjs)"
fi

for j in manifest.json schemas.json profiles.json; do
    [[ -f "$j" ]] || { skip "$j not present"; continue; }
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$j" 2>/dev/null
    then pass "$j is valid JSON"; else fail "$j is not valid JSON"; fi
done
for p in bin/*.py; do
    [[ -e "$p" ]] || continue
    # compile(), not py_compile: it proves the file parses without writing a
    # __pycache__ into the source tree, where the next deploy would ship it.
    if python3 -c 'import sys; compile(open(sys.argv[1],"rb").read(), sys.argv[1], "exec")' "$p" 2>/dev/null
    then pass "$p compiles"; else fail "$p does not compile"; fi
done

# ------------------------------------------------- deployment bans ----------
head_ "Deployment bans (DEPLOY-CONTRACT sections 2.4, 4.4, 7.2)"

# THE ONE THE TASK NAMES: no deployed artifact may contain a dev-tree path.
# Had this existed in samba-ad-lab it would have caught all thirteen
# occurrences of the retired path, including the two that are broken today -
# a manifest condition pointing at a file that does not exist, which makes a
# Cockpit plugin SILENTLY ABSENT, and a SECRET_DIR that makes a build create an
# empty secrets directory at a dead path.
scan=("${PAGE[@]}")
for f in "${EXTRA[@]}"; do [[ -e "$f" ]] && scan+=("$f"); done
[[ -f "$ENVDEFAULT" ]] && scan+=("$ENVDEFAULT")
for d in README.md LICENSE; do [[ -f "$d" ]] && scan+=("$d"); done
for u in "${UNITS[@]}"; do
    [[ -f "systemd/$u.in" ]] && scan+=("systemd/$u.in")
    [[ -f "systemd/$u" ]]    && scan+=("systemd/$u")
done
if hits=$(grep -RIn -e '/opt/sc/git' -e "$DEV_ROOT_PAT" -- "${scan[@]}" 2>/dev/null); then
    fail "a shipped file hardcodes a dev-tree or retired path - it belongs in .env"
    printf '%s\n' "$hits" | sed 's/^/        /' | head -8
else
    pass "no shipped artifact names a dev-tree or retired path"
fi

# section 4.4 grep 1 - no shipped file names a source .env.
if grep -RIn -e 'source/\.env' -- "${scan[@]}" 2>/dev/null | grep -q .; then
    fail "a shipped file names a source .env (that file is TEST-ONLY)"
else pass "no shipped file names a source .env"; fi

# section 4.4 grep 2 - nothing resolves .env relative to itself. The whole
# reason install.conf exists is that the same "beside me" line is right on a
# deployed host and wrong in a dev install, where it reads the test-only .env.
if grep -RIn -e 'dirname.*\.env' -e '__file__.*\.env' -e 'BASH_SOURCE.*\.env' \
        -- bin/ 2>/dev/null | grep -q .; then
    fail "a payload script resolves .env relative to itself"
else pass "nothing resolves .env relative to itself"; fi

# section 4.4 grep 3 - anything that reads config reads install.conf, or nothing.
bad=""
for f in bin/*.py; do
    [[ -e "$f" ]] || continue
    grep -qE 'load_env|\.env' "$f" || continue
    grep -q 'install\.conf' "$f" || bad+="$f "
done
if [[ -n "$bad" ]]; then fail "reads .env but never mentions install.conf: $bad"
else pass "every config reader goes through install.conf"; fi

# section 2.4 - the recursive-removal ban. rm -rf on a path that is a symlink
# into the checkout, with one trailing slash, deletes the checkout. The only
# recursion allowed anywhere is deploy.sh's remove_old_payload, which asserts
# three times against a $ROOT_REAL resolved once.
# install.sh must contain NO recursion at all. deploy.sh gets exactly two:
# the $NEW.tmp staging directory it just created itself, and the one inside
# remove_old_payload, which asserts three times against a $ROOT_REAL resolved
# once before it runs.
    # Heredoc bodies are TEXT PRINTED TO THE OPERATOR, not commands this script
# runs, and install.sh's uninstall notice legitimately shows the operator
# the `rm -rf` they would type by hand to remove their own data. Stripping
# heredoc bodies before the scan makes this check MORE precise rather than
# excusing a pattern - an exception list would have had to grow every time
# the advice was reworded, and a check with an exception list is a check
# with a blind spot.
strip_heredocs() {
    awk '
        inhere { if ($0 == term || $0 == "\t" term) inhere = 0; next }
        {
            line = $0
            if (match(line, /<<-?[[:space:]]*'\''?"?[A-Za-z_][A-Za-z0-9_]*'\''?"?/)) {
                t = substr(line, RSTART, RLENGTH)
                gsub(/^<<-?[[:space:]]*/, "", t); gsub(/['\''"]/, "", t)
                term = t; inhere = 1
            }
            print NR ":" line
        }
    ' "$1"
}
offenders=""
for s in install.sh deploy.sh; do
    [[ -f "$s" ]] || continue
    while IFS= read -r line; do
        offenders+="$s: $line"$'\n'
    done < <(strip_heredocs "$s" \
             | grep -E 'rm[[:space:]]+-[a-zA-Z]*r|find[[:space:]].*-delete|rsync.*--delete' \
             | grep -vE '^[0-9]+:[[:space:]]*#' \
             | { if [[ "$s" == deploy.sh ]]; then grep -vE 'rm -rf -- "\$NEW\.tmp"|rm -rf -- "\$real"'; else cat; fi; })
done
if [[ -n "$offenders" ]]; then
    fail "a recursive removal outside remove_old_payload"
    printf '%s' "$offenders" | sed 's/^/        /' | head -6
else pass "no recursive removal outside remove_old_payload"; fi

# section 6.1 - neither script may touch cockpit.socket. Cockpit is live on this
# host; it rescans its package directory when a session starts, and a page
# reload is sufficient.
# Precise: a COMMAND acting on it, not a comment mentioning it. Both scripts
# say in prose that they leave it alone, and a check that cannot tell prose from
# a systemctl call is a check that gets disabled.
if grep -RIn 'cockpit\.socket' install.sh deploy.sh 2>/dev/null \
       | grep -E 'systemctl|service |systemd-run' | grep -q .; then
    fail "install.sh or deploy.sh touches cockpit.socket"
else pass "neither script touches cockpit.socket"; fi

# section 6.1 - install.sh renders and places units; it never changes the
# running state of the host. Only deploy.sh may, and only behind a flag.
if grep -nE 'systemctl( --user)? (enable|start|restart)' install.sh \
        | grep -vE '^\s*[0-9]+:\s*#|echo|cat|EOF|systemctl --user enable --now cockpit-tuner' | grep -q .; then
    fail "install.sh enables or starts a unit"
else pass "install.sh never enables or starts a unit"; fi

# section 4.1 - .envdefault must parse under the one grammar.
if [[ -f "$ENVDEFAULT" ]]; then
    if python3 - "$ENVDEFAULT" <<'PY' 2>&1
import re, sys
path = sys.argv[1]
for n, raw in enumerate(open(path, encoding="utf-8"), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        sys.exit("%s:%d: not KEY=VALUE" % (path, n))
    k, v = (x.strip() for x in line.split("=", 1))
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", k):
        sys.exit("%s:%d: bad key %r" % (path, n, k))
    if len(v) >= 2 and v[0] == v[-1] == '"':
        v = v[1:-1]
    if any(c in v for c in "$`"):
        sys.exit("%s:%d: %s contains $ or ` (no interpolation, section 4.1)" % (path, n, k))
PY
    then pass "$ENVDEFAULT parses under the section 4.1 grammar"
    else fail "$ENVDEFAULT violates the section 4.1 grammar"; fi

    missing=""
    for k in "${REQUIRED_ENV[@]}"; do
        grep -qE "^[[:space:]]*$k=" "$ENVDEFAULT" || missing+="$k "
    done
    if [[ -n "$missing" ]]; then fail "$ENVDEFAULT does not declare REQUIRED_ENV: $missing"
    else pass "$ENVDEFAULT declares all ${#REQUIRED_ENV[@]} REQUIRED_ENV key(s)"; fi
else skip "$ENVDEFAULT not present"; fi

# section 4.2 - a deployed .env must never carry a secret VALUE. Checked on the
# committed default too, because that is what gets copied on a fresh deploy.
if [[ -f "$ENVDEFAULT" ]]; then
    leak=""
    while IFS='=' read -r k v; do
        [[ "$k" =~ (PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|PASSPHRASE) ]] || continue
        [[ "$k" =~ _(FILE|PATH|DIR|NAME|ID)$ ]] && continue
        [[ -z "$v" ]] && continue
        leak+="$k "
    done < <(grep -v '^[[:space:]]*#' "$ENVDEFAULT" | grep '=' || true)
    if [[ -n "$leak" ]]; then fail "$ENVDEFAULT holds a secret-shaped value: $leak"
    else pass "$ENVDEFAULT holds no secret-shaped value"; fi
fi

# ---------------------------------------------- completeness (section 7.2) ---
head_ "Completeness gate"
if [[ -x install.sh ]]; then
    # The gate lives in install.sh and refuses there. Running it in --help mode
    # only proves it parses; the real proof is the staged install in the README.
    if bash -n install.sh 2>&1; then pass "install.sh parses"; else fail "install.sh has a syntax error"; fi
    if bash -n deploy.sh 2>&1; then pass "deploy.sh parses"; else fail "deploy.sh has a syntax error"; fi
else skip "install.sh not executable"; fi

# Every page-local file app.js fetch()es at runtime must be in PAGE. index.html
# never mentions schemas.json, so the HTML parse in install.sh cannot see this,
# and a payload that shipped it as data would serve a plugin whose every panel
# is empty.
runtime=$(grep -ohE '(fetch|fetchJSON)\([[:space:]]*"[^"/]+\.[A-Za-z0-9]+"' "${PAGE[@]}" 2>/dev/null \
          | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)
bad=""
for r in $runtime; do printf '%s\n' "${PAGE[@]}" | grep -qxF "$r" || bad+="$r "; done
if [[ -n "$bad" ]]; then fail "fetched at runtime but not in PAGE: $bad"
else pass "every runtime fetch() resolves to a shipped page file (${runtime//$'\n'/, })"; fi

printf '\n'
((rc)) && printf '\033[31mvalidate.sh: FAILED\033[0m\n' || printf '\033[32mvalidate.sh: OK\033[0m\n'
exit $rc
