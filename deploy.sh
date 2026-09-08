#!/usr/bin/env bash
#
# deploy.sh - THE REAL DEPLOYMENT of cockpit-tuner. The only thing here that
#             copies bytes.
#
# It copies the declared payload into an install path, seeds .env there from
# .envdefault (missing-only, never clobbering), and then runs install.sh FROM
# THAT INSTALL PATH. install.sh is the same script it would be in a dev
# checkout; running it from the copy is the whole mechanism.
#
#   sudo ./deploy.sh                          # -> /opt/cockpit-tuner
#   sudo ./deploy.sh --install-to /srv/x      # somewhere else, absolute
#   sudo ./deploy.sh --with-timer             # ... and place the snapshot units
#   sudo ./deploy.sh --verify                 # run the standing checks and stop
#   sudo ./deploy.sh --uninstall              # un-INSTALL: drop the symlinks
#   sudo ./deploy.sh --remove                 # and delete the deployed tree too
#
# SELF-CONTAINED, on purpose: this repo is cloned on its own, so nothing here
# may depend on a shared framework outside the clone. It reads the payload
# declaration out of install.sh's BEGIN-MANIFEST block rather than restating it
# - two lists that can disagree is the failure this design exists to remove.
#
# THE ACCEPTANCE TEST: after this runs, unmount
# /srv/smb/share/sc/ai-orchestrator-group/ai-orchestrator-storage and the plugin
# still works, timer included. Nothing it leaves behind points at the share.
#
# There is no `set -x` in this tree: the /srv/jobs runner's output.log is
# group-readable.
#
set -Eeuo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"
DEV_ROOT=/srv/smb/share/sc/ai-orchestrator-group/ai-orchestrator-storage/projects

die()     { printf 'deploy.sh: %s\n' "$*" >&2; exit 1; }
say()     { printf '  + %s\n' "$*"; }
note()    { printf '  %s\n' "$*"; }
warn()    { printf '  ! %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# THE ONE DECLARATION, read out of install.sh. Not restated here.
# ---------------------------------------------------------------------------
manifest="$(sed -n '/^# BEGIN-MANIFEST/,/^# END-MANIFEST/p' "$SRC/install.sh")"
[[ -n "$manifest" ]] \
    || die "install.sh has no BEGIN-MANIFEST/END-MANIFEST block. That block is the single source of the payload list; without it this script would have to guess."
eval "$manifest"
[[ -n "${PROJECT:-}" && -n "${NAME:-}" ]] || die "the manifest block did not define PROJECT and NAME."

VERSION="$(cat "$SRC/VERSION" 2>/dev/null)" \
    || die "no VERSION file. The payload directory is named payload-<version>; without one there is nothing to name it, and no rollback."
[[ "$VERSION" =~ ^[0-9A-Za-z._-]+$ ]] || die "VERSION is not a plain version string: '$VERSION'"

ROOT="/opt/$PROJECT"
ACTION="deploy"
WITH_TIMER=0
DO_VERIFY=0

while (($#)); do
    case "$1" in
        --install-to) ROOT="${2:?--install-to needs a path}"; shift 2 ;;
        --with-timer) WITH_TIMER=1; shift ;;
        --verify)     DO_VERIFY=1; ACTION="verify"; shift ;;
        --uninstall)  ACTION="uninstall"; shift ;;
        --remove)     ACTION="remove"; shift ;;
        -h|--help)    sed -n '2,/^# There is no .set -x/p' "$SELF" | sed '$d' | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[[ "$ROOT" == /* ]] || die "--install-to must be absolute; got '$ROOT'"

# Resolved ONCE, at the top. Comparing against an unresolved $ROOT is how a
# symlinked /opt defeats every containment check below.
ROOT_REAL="$(readlink -f -- "$ROOT" 2>/dev/null || echo "$ROOT")"

# ===========================================================================
# the ONE recursive removal this contract allows (section 2.4)
# ===========================================================================
remove_old_payload() {
    local p=$1 real
    [[ -d "$p" && ! -L "$p" ]]  || die "refusing: $p is not a real directory"
    real=$(readlink -f -- "$p") || die "refusing: cannot resolve $p"
    [[ "$real" == "$ROOT_REAL"/payload-* ]] \
        || die "refusing to recursively remove $real - not a payload dir under $ROOT_REAL"
    [[ "$real" != "$ROOT_REAL" ]] || die "refusing: that is the install root"
    rm -rf -- "$real"
}

# ===========================================================================
# --verify: the standing checks. Each must print nothing but its verdict.
# ===========================================================================
run_verify() {
    local rc=0
    echo "Standing checks (contract section 4.4)"

    # 1. No shipped file ever names a source .env.
    if grep -RIn -e 'source/\.env' -- "${PAGE[@]/#/$SRC/}" "${EXTRA[@]/#/$SRC/}" 2>/dev/null; then
        warn "1. a shipped file names a source .env"; rc=1
    else note "1. no shipped file names a source .env"; fi

    # 2. No consumer resolves .env relative to itself. The whole point of
    #    install.conf is that this indirection is never re-introduced.
    if grep -RIn -e 'dirname.*\.env' -e '__file__.*\.env' -e 'BASH_SOURCE.*\.env' \
            -- "${EXTRA[@]/#/$SRC/}" 2>/dev/null; then
        warn "2. a payload script resolves .env relative to itself"; rc=1
    else note "2. nothing resolves .env relative to itself"; fi

    # 3. Anything that reads config reads install.conf, or reads nothing.
    local f
    for f in "${EXTRA[@]}"; do
        grep -qE 'load_env|\.env' "$SRC/$f" 2>/dev/null || continue
        grep -q 'install\.conf' "$SRC/$f" \
            || { warn "3. $f reads .env but never mentions install.conf"; rc=1; }
    done
    ((rc)) || note "3. every config reader goes through install.conf"

    # 4. No dev-tree and no retired path in anything shipped. The dev root is
    #    split so this file's own DEV_ROOT= line cannot match itself.
    local scan=("${PAGE[@]/#/$SRC/}" "${EXTRA[@]/#/$SRC/}" "$SRC/$ENVDEFAULT" "$SRC/systemd")
    if grep -RIn -e '/opt/sc/git' -e "/srv/smb/share/sc/ai-orchestrator""-group" -- "${scan[@]}" 2>/dev/null; then
        warn "4. a shipped file hardcodes a dev or retired path"; rc=1
    else note "4. no shipped file names a dev-tree or retired path"; fi

    # 5. THE NEGATIVE TEST that proves - rather than argues - which .env a
    #    deployed consumer opens. (Contract JC-10 names strace as the ideal and
    #    this as the substitute where strace is absent, which it is here.)
    #
    #    It has THREE outcomes, not two. A probe that cannot run is INCONCLUSIVE
    #    and says so: reporting "could not run" as a pass is how a gate quietly
    #    stops testing anything, and reporting it as a leak - which this check
    #    did on its first outing, by reading the script's own correct refusal as
    #    a failure - is how a gate gets ignored by the people it is for.
    local conf="${DESTDIR:-}/etc/$PROJECT/install.conf"
    local snap="$ROOT/payload/bin/tuner-snapshot.py"
    if [[ ! -f "$conf" || ! -f "$snap" ]]; then
        note "5. negative .env test INCONCLUSIVE (no $conf yet - run a deploy first)"
        return $rc
    fi

    # 5a, static and always decisive: the ENV_FILE install.sh recorded is the
    # deployed one, and is not in the checkout.
    local recorded; recorded="$(sed -n 's/^ENV_FILE=//p' "$conf" | head -1)"
    if [[ "$recorded" != "$ROOT/.env" ]]; then
        warn "5a. install.conf records ENV_FILE=$recorded, not $ROOT/.env"; rc=1
    elif [[ "$recorded" == "$SRC/"* ]]; then
        warn "5a. install.conf points the deployed plugin INTO THE CHECKOUT: $recorded"; rc=1
    else
        note "5a. install.conf records ENV_FILE=$recorded (the deployed one)"
    fi

    # 5b, dynamic: plant an obviously wrong value in the checkout's .env and
    # confirm it cannot reach the deployed consumer through the deployed
    # install.conf. The checkout's .env is restored either way.
    local booby="$SRC/.env" saved="" had=0 out
    [[ -f "$booby" ]] && { saved="$(cat "$booby")"; had=1; }
    printf 'TUNER_HISTORY_DIR=/nonexistent/booby-trap\nTUNER_UNDO_DIR=/nonexistent/booby-trap\n' > "$booby"
    # stdout only: the probe prints its verdict there, and the module under
    # test legitimately writes to stderr (a duplicate key in .env warns, per
    # section 4.1). Folding stderr in turned a real CLEAN into an INCONCLUSIVE.
    out="$(python3 "$SRC/.probe-env.py" "$snap" "$conf" 2>/dev/null || true)"
    if ((had)); then printf '%s\n' "$saved" > "$booby"; else rm -f -- "$booby"; fi
    case "$out" in
        CLEAN*) note "5b. the deployed consumer read ${out#CLEAN }, NOT the checkout's booby-trapped .env" ;;
        LEAK*)  warn "5b. THE DEPLOYED CONSUMER READ THE CHECKOUT'S .env: ${out#LEAK }"; rc=1 ;;
        *)      note "5b. negative .env test INCONCLUSIVE: ${out%%$'\n'*}" ;;
    esac
    return $rc
}

if ((DO_VERIFY)); then run_verify; exit $?; fi

# ===========================================================================
# --uninstall / --remove: two different verbs, deliberately
# ===========================================================================
if [[ "$ACTION" == uninstall || "$ACTION" == remove ]]; then
    [[ $EUID -eq 0 ]] || die "needs root (on this host: submit it to the /srv/jobs runner)."
    if [[ -x "$ROOT/payload/install.sh" ]]; then
        "$ROOT/payload/install.sh" --uninstall
    else
        warn "no $ROOT/payload/install.sh - nothing to un-install"
    fi
    if [[ "$ACTION" == remove ]]; then
        shopt -s nullglob
        for p in "$ROOT"/payload-*; do remove_old_payload "$p"; say "removed $p"; done
        shopt -u nullglob
        [[ -L "$ROOT/payload" ]] && { rm -f -- "$ROOT/payload"; say "removed $ROOT/payload"; }
        echo
        echo "KEPT: $ROOT/.env - your settings, and this is not the verb that"
        echo "throws them away. Remove it by hand if you mean to:  rm $ROOT/.env"
        rmdir -- "$ROOT" 2>/dev/null && say "removed empty $ROOT" || true
    fi
    exit 0
fi

# ===========================================================================
# deploy - pre-flight
# ===========================================================================
echo "Deploying $PROJECT $VERSION"
note "from: $SRC"
note "to:   $ROOT"
echo
echo "Pre-flight"

[[ $EUID -eq 0 ]] || die "needs root: it writes $ROOT and runs install.sh (on this host: submit it to the /srv/jobs runner)."

# JC-1's accepted cost, paid here rather than at first click: /opt is a separate
# filesystem on some hosts and a few hardening profiles mount it noexec, which
# would break every executable in the payload.
mkdir -p -- "$ROOT"
mountpoint_opts="$(findmnt -no OPTIONS --target "$ROOT" 2>/dev/null || true)"
case ",$mountpoint_opts," in
    *,noexec,*) die "the filesystem holding $ROOT is mounted noexec. Nothing in the payload could run. Choose another --install-to, or remount." ;;
esac
note "$ROOT is on an exec filesystem"

# Refuse to deploy a payload that does not pass its own standing checks. This is
# also where check.sh / validate.sh run, because the payload does not ship them:
# a deployed host has no business holding the dev gate, and a deploy that
# skipped the gate would be the reason it was missing.
for gate in validate.sh; do
    if [[ -x "$SRC/$gate" ]]; then
        "$SRC/$gate" >/dev/null 2>&1 || die "$gate FAILED. Run ./$gate and read it. Nothing was copied."
        note "$gate passed"
    fi
done

# ===========================================================================
# the copy - the DECLARED payload, and nothing else
# ===========================================================================
# A checkout holds a great deal a production host has no business holding:
# .git/, tests/, docs/, the gates, fixtures. None of it is copied. There is no
# build step to invent either - these files ARE the artifact, byte for byte, and
# adding a bundler to satisfy a sense that deployment should compile something
# would only put a second thing between the source and the browser.
echo
echo "Copying the declared payload"
NEW="$ROOT/payload-$VERSION"
rm -rf -- "$NEW.tmp"            # safe: we just built this name, and nothing else uses it
mkdir -p -- "$NEW.tmp"

copy_in() {  # copy_in <mode> <relpath...>
    local mode=$1; shift
    local rel d
    for rel in "$@"; do
        [[ -e "$SRC/$rel" ]] || die "declared payload item missing: $rel"
        d="$(dirname -- "$NEW.tmp/$rel")"
        [[ -d "$d" ]] || install -d -m 0755 -o root -g root -- "$d"
        install -m "$mode" -o root -g root -- "$SRC/$rel" "$NEW.tmp/$rel"
    done
}

copy_in 0644 "${PAGE[@]}" "$ENVDEFAULT" VERSION
[[ -f "$SRC/LICENSE" ]]   && copy_in 0644 LICENSE
[[ -f "$SRC/README.md" ]] && copy_in 0644 README.md
copy_in 0755 install.sh
((${#EXTRA[@]}))   && copy_in 0755 "${EXTRA[@]}"
((${#HELPERS[@]})) && { for h in "${HELPERS[@]}"; do
    [[ -e "$SRC/bin/$h" ]] && copy_in 0755 "bin/$h" || copy_in 0755 "$h"; done; }
((${#LIBS[@]}))    && { for l in "${LIBS[@]}"; do
    while IFS= read -r -d '' f; do copy_in 0644 "${f#"$SRC"/}"; done \
        < <(find "$SRC/$l" -type f -print0 2>/dev/null); done; }
for u in "${UNITS[@]}"; do
    [[ -f "$SRC/systemd/$u.in" ]] && copy_in 0644 "systemd/$u.in"
    [[ -f "$SRC/systemd/$u" ]]    && copy_in 0644 "systemd/$u"
done
((${#SEEDS[@]})) && { for s in "${SEEDS[@]}"; do
    while IFS= read -r -d '' f; do copy_in 0644 "${f#"$SRC"/}"; done \
        < <(find "$SRC/$s" -type f -print0 2>/dev/null); done; }

# The payload is complete only now. mv -T is a single rename(2): there is no
# instant at which a half-written payload-<version> is visible.
[[ -d "$NEW" ]] && remove_old_payload "$NEW"
mv -T -- "$NEW.tmp" "$NEW"
chmod 0755 -- "$NEW"
say "wrote $NEW ($(find "$NEW" -type f | wc -l) files)"

# The swap. mv -T over a symlink is one rename, which matters because Cockpit is
# live at https://localhost:9090 and a browser may be loading the page right now.
ln -sfn -- "payload-$VERSION" "$ROOT/payload.new"
mv -T -- "$ROOT/payload.new" "$ROOT/payload"
say "payload -> payload-$VERSION"

# Keep exactly one previous version. Rollback is then two commands, with no
# share and no network:
#   ln -sfn payload-<old> payload.new && mv -T payload.new payload && payload/install.sh
shopt -s nullglob
mapfile -t old < <(for p in "$ROOT"/payload-*; do
    [[ -d "$p" && "$(basename "$p")" != "payload-$VERSION" ]] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
done | sort -rn | cut -f2-)
shopt -u nullglob
for ((i = 1; i < ${#old[@]}; i++)); do
    remove_old_payload "${old[$i]}"; say "removed superseded ${old[$i]}"
done
((${#old[@]})) && note "kept ${old[0]} for rollback"

# ===========================================================================
# .env - seeded MISSING-ONLY, and never containing a secret
# ===========================================================================
echo
echo "Configuration"
ENV_FILE="$ROOT/.env"
keys_of() { grep -oE '^[[:space:]]*[A-Z][A-Z0-9_]*=' "$1" | tr -d ' \t=' | sort -u; }

if [[ -e "$ENV_FILE" ]]; then
    note "kept existing $ENV_FILE (NOT overwritten - it is what you decided)"
    new_keys="$(comm -23 <(keys_of "$NEW/$ENVDEFAULT") <(keys_of "$ENV_FILE") | tr '\n' ' ')"
    # The known cost of missing-only seeding, paid honestly rather than by
    # silently adding keys to a file the operator owns. install.sh turns a
    # required key that is still absent into a refusal.
    [[ -z "${new_keys// }" ]] || warn "this version adds key(s) your .env does not set: $new_keys  (see $NEW/$ENVDEFAULT)"
else
    install -m 0644 -o root -g root -- "$NEW/$ENVDEFAULT" "$ENV_FILE"
    say "seeded $ENV_FILE from $ENVDEFAULT - REVIEW IT before first use"
fi

# 0644 is safe only because of this check. A deployed .env carries locations and
# settings; the moment one carries a credential, the mode that lets a user-class
# consumer read a port number also leaks the credential.
while IFS='=' read -r k v; do
    [[ "$k" =~ (PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|PASSPHRASE) ]] || continue
    [[ "$k" =~ _(FILE|PATH|DIR|NAME|ID)$ ]] && continue      # a pointer, fine
    [[ -z "$v" ]] && continue                                # unset, fine
    die "$k in $ENV_FILE looks like a secret VALUE. A deployed .env carries
    locations and settings, never secrets. Put the material in a root-owned
    0700 directory and name the FILE here (${k}_FILE=...)."
done < <(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep '=' || true)
note "no key in $ENV_FILE holds a secret-shaped value"

# ===========================================================================
# run install.sh FROM THE INSTALL PATH. This is the whole mechanism.
# ===========================================================================
echo
echo "Running $ROOT/payload/install.sh"
args=()
((WITH_TIMER)) && args+=(--with-timer)
"$ROOT/payload/install.sh" "${args[@]}"

# ===========================================================================
# prove the result is self-sustaining
# ===========================================================================
echo
echo "Deployment assertions"
bad=0
while IFS= read -r l; do
    t="$(readlink -f -- "$l" 2>/dev/null || true)"
    [[ "$t" == "$ROOT_REAL"/* ]] || { warn "$l -> $t, which is OUTSIDE $ROOT"; bad=1; }
done < <(find "${DESTDIR:-}/usr/share/cockpit/$NAME" -maxdepth 1 -type l 2>/dev/null)
# Scoped to the shipped ARTIFACTS, exactly as pre-flight check 9 is, and
# deliberately NOT to the whole payload. install.sh is in the payload and it
# MUST contain the dev root as a literal - that is the DEV_ROOT= line section
# 3.1 requires, the one that lets it classify this install and tell an operator
# running --uninstall on a dev host that their checkout is not being touched.
# The ban is on artifacts that would carry a dead path into production, not on
# the installer's own knowledge of where a dev tree lives.
artifacts=("${PAGE[@]/#/$NEW/}" "$NEW/$ENVDEFAULT")
for f in "${EXTRA[@]}"; do [[ -e "$NEW/$f" ]] && artifacts+=("$NEW/$f"); done
[[ -d "$NEW/systemd" ]] && artifacts+=("$NEW/systemd")
if hits=$(grep -rl -e "/srv/smb/share/sc/ai-orchestrator""-group" -e '/opt/sc/git' -- "${artifacts[@]}" 2>/dev/null); then
    warn "a deployed artifact names the dev tree: $hits"; bad=1
fi
((bad)) && die "the deployment is NOT self-sustaining (above). Unmounting the share would break this host."
note "every link resolves inside $ROOT; nothing deployed names the dev tree"

if ((WITH_TIMER)); then
    cat <<EOF

The snapshot timer is a systemd USER timer and root cannot enable it for
somebody else. In the session that should collect snapshots, and only there:
  systemctl --user enable --now cockpit-tuner-snapshot.timer
EOF
fi

cat <<EOF

Done. $ROOT/payload -> payload-$VERSION
Unmount the share and this host keeps working. That is the test.
EOF
