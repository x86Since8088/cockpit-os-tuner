#!/usr/bin/env bash
#
# install.sh - the IN-PLACE install, BY SYMLINK, of the cockpit-tuner plugin.
#
# It does NOT copy the payload. It links the files this directory ships into the
# places Cockpit and systemd look, and it records what it did. Run it from a dev
# checkout and you get a dev install whose page is a set of symlinks into the
# checkout, so editing app.js changes what the browser loads on the next reload.
# Run the IDENTICAL script from /opt/cockpit-tuner/payload and you get a
# production install whose links point at a tree with no relationship to the
# share. The script is the same; only where it is run from differs.
#
#   sudo ./install.sh                  # link into /usr/share/cockpit/tuner
#   sudo ./install.sh --with-timer     # ... and render the snapshot units
#   sudo ./install.sh --uninstall      # remove the links; keep every byte of data
#        ./install.sh --user           # per-user: ~/.local/share/cockpit/tuner
#        ./install.sh --env-file PATH  # override where .env is read from
#   sudo DESTDIR=/tmp/stage ./install.sh   # stage into a build root
#
# It never copies the payload, never enables or starts a unit, and never touches
# cockpit.socket - Cockpit is live on this host and rescans its package
# directory on the next page load. See docs/DEPLOY-CONTRACT.md in
# cockpit-secrets, which governs this file; section numbers below refer to it.
#
# What it touches, and nothing else:
#
#   /usr/share/cockpit/tuner/           a REAL directory of per-file symlinks
#   /etc/cockpit-tuner/install.conf     the machine's record of this install
#   /var/lib/cockpit-tuner/             the root-owned undo journal's directory
#   /usr/local/lib/systemd/user/        --with-timer only, rendered, NOT enabled
#
# --uninstall removes exactly those symlinks and units. It keeps
# /var/lib/cockpit-tuner (the undo journal), every ~/.local/share/cockpit-tuner
# history directory, and the .env - an uninstall removes software, not data.
#
# There is no `set -x` in this tree: root work on this host goes through the
# /srv/jobs runner and its output.log is group-readable.
#
set -Eeuo pipefail

# ===========================================================================
# BEGIN-MANIFEST
#
# THE ONE DECLARATION (contract section 7.1). deploy.sh reads this exact block
# out of this exact file rather than restating it. Two lists that can disagree
# is the failure mode being designed out here, and re-declaring the payload in
# the deploy script is the obvious way to re-introduce it.
# ---------------------------------------------------------------------------
PROJECT="cockpit-tuner"          # the repo dir, and the /opt/<project> name
NAME="tuner"                     # the Cockpit package name, /usr/share/cockpit/<name>

# Files served to the browser. Linked per-file into a REAL /usr/share/cockpit/
# <name> directory (section 2.1). schemas.json and profiles.json are in here
# because app.js fetch()es them at runtime: they are page files, not payload
# data, and pre-flight check 2b below is what proves that claim.
PAGE=(manifest.json index.html adapter.js app.js tuner.css schemas.json profiles.json)

# Verb helpers linked into /usr/local/sbin. This plugin has NONE: it drives
# sysctl and systemctl through cockpit.spawn directly and ships no root helper.
# Pre-flight check 3 enforces that the page never calls one that is not here.
HELPERS=()

# Python/JS packages linked into /usr/local/lib/<project>. None: nothing outside
# the payload imports anything this plugin ships.
LIBS=()

# Shipped in the payload, linked NOWHERE. The snapshot collector is run by the
# unit below, by absolute path into the payload; it is deliberately not in PAGE,
# because a python script has no business being served over HTTPS from a web
# root, which is exactly where the previous installer put it.
EXTRA=(bin/tuner-snapshot.py bin/tuner-crawl.py)

# systemd units. Rendered from <name>.in when a template exists, copied when it
# does not, and NEVER enabled or started by this script (section 6.1).
UNITS=(cockpit-tuner-snapshot.service cockpit-tuner-snapshot.timer)

# Seed data for /etc/<project>. None: this plugin manages no system data files.
SEEDS=()

ENVDEFAULT=.envdefault

# Keys .env must define, non-empty, or the install refuses (check 7).
REQUIRED_ENV=(TUNER_HISTORY_DIR TUNER_UNDO_DIR)
# END-MANIFEST
# ===========================================================================

# ---------------------------------------------------------------------------
# Where am I? readlink -f FIRST, then dirname (section 3.1). Resolving the
# dirname of an unresolved $0 makes a script invoked through a symlink look for
# its payload in the LINK's directory, which is how an installer silently
# installs the wrong tree.
# ---------------------------------------------------------------------------
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"
VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo 0.0.0)"

# The install root is the payload's parent: /opt/cockpit-tuner for
# /opt/cockpit-tuner/payload-1.0.0. .env is a SIBLING of the payload, never a
# child of it, which is the only way "seed .env in the install path" and
# "an upgrade never touches operator config" can both be true (section 1.3).
ROOT="$(cd -- "$SRC/.." && pwd)"
ROOT_REAL="$(readlink -f -- "$ROOT")"

# WHICH KIND OF INSTALL IS THIS? Decided by LAYOUT, never by a path prefix.
# Used ONLY to record and to warn (section 3.1) - never to decide what gets
# linked. The moment dev and prod grow different link logic, the thing you
# tested is not the thing you shipped.
#
# deploy.sh writes <install path>/payload-<version>/ and points a sibling
# `payload` symlink at it; swapping that one symlink IS an upgrade or a
# rollback. So this is a DEPLOYED payload exactly when our own directory is
# what that symlink resolves to. A checkout has no such symlink.
#
# This replaces an older `$SRC == $DEV_ROOT/*` test that named the share
# literally. That test was wrong for any checkout sitting anywhere else: a
# plain checkout copied outside the share called itself `deployed`, so it
# skipped the group-writable warning, recorded INSTALL_KIND=deployed for a
# host that was NOT self-sustaining, and dropped "the checkout is not touched"
# from --uninstall. Layout cannot drift when a tree moves, and it leaves no
# dev-root literal in a shipped file - which is why check 9 below now scans
# this installer too, with no carve-out.
# NB: computed from $SRC, never from $ROOT - in some of these installers ROOT
# is derived FROM KIND, so reading it here would be a use-before-assignment
# that silently classified every deployed payload as `dev`.
# Two ways to be a deployed payload. The first is the normal one: the `payload`
# alias points at us. The second covers a PREVIOUS payload being run directly -
# a rollback done without swapping the alias first - which is still a deployed
# tree, not a checkout, and must not be told to go and create a test .env.
if [[ "$(readlink -f -- "$SRC/../payload" 2>/dev/null)" == "$SRC" ]] \
   || { [[ "${SRC##*/}" == payload-* ]] && [[ -L "$SRC/../payload" ]]; }
then KIND=deployed
else KIND=dev
fi

umask 022
DESTDIR="${DESTDIR:-}"
SCOPE="system"
ACTION="install"
WITH_TIMER=0
ENV_FILE=""

usage() {
    sed -n '2,/^# There is no .set -x/p' "$SELF" | sed '$d' | sed 's/^# \?//'
    exit "${1:-0}"
}

while (($#)); do
    case "$1" in
        --user)       SCOPE="user"; shift ;;
        --system)     SCOPE="system"; shift ;;
        --uninstall)  ACTION="uninstall"; shift ;;
        --with-timer) WITH_TIMER=1; shift ;;
        --env-file)   ENV_FILE="${2:?--env-file needs a path}"; shift 2 ;;
        -h|--help)    usage 0 ;;
        *) printf 'install.sh: unknown option: %s\n\n' "$1" >&2; usage 1 ;;
    esac
done

# --------------------------------------------------------------- reporting ---
CHANGES=(); KEPT=(); WARNINGS=()
changed() { CHANGES+=("$*"); printf '  + %s\n' "$*"; }
kept()    { KEPT+=("$*");    printf '  = %s\n' "$*"; }
warn()    { WARNINGS+=("$*"); printf '  ! %s\n' "$*" >&2; }
note()    { printf '  %s\n' "$*"; }
die()     { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- destinations ---
if [[ "$SCOPE" == user ]]; then
    PKGDIR="${XDG_DATA_HOME:-$HOME/.local/share}/cockpit/$NAME"
    CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}/$PROJECT"
    UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
else
    PKGDIR="$DESTDIR/usr/share/cockpit/$NAME"
    CONFDIR="$DESTDIR/etc/$PROJECT"
    # JC-11: this project keeps its units under /usr/local/lib, which is where
    # cockpit-secrets already puts its user units. The choice is recorded in
    # install.conf so --uninstall on a host installed by a different version
    # still finds them.
    UNITDIR="$DESTDIR/usr/local/lib/systemd/user"
fi
INSTALL_CONF="$CONFDIR/install.conf"

# .env lives beside the payload on a deployed host. In a dev checkout there is
# no install root to put one in, so the checkout's own .env is used - and that
# file is TEST-ONLY (see .envdefault and .gitignore). This is the one difference
# section 3.2 sanctions; it changes where config is READ, never what is LINKED.
if [[ -z "$ENV_FILE" ]]; then
    if [[ "$KIND" == dev ]]; then ENV_FILE="$SRC/.env"; else ENV_FILE="$ROOT/.env"; fi
fi

# ===========================================================================
# the safe removal idiom (contract section 2.4) - copied verbatim, on purpose
# ===========================================================================
# rm -rf on a path that is a symlink into the dev checkout, with one trailing
# slash, deletes the dev checkout. Nothing below recurses, and nothing below
# follows a link.
remove_link() {
    local p=$1
    if [[ -L "$p" ]]; then
        rm -f -- "$p"          # removes the LINK. The target is untouched.
        changed "unlinked $p"
    elif [[ -e "$p" ]]; then
        warn "$p is not a symlink - left in place, remove it by hand if you meant to"
    fi
}

remove_dir_if_empty() {
    local p=$1
    [[ -d "$p" && ! -L "$p" ]] || return 0
    if rmdir -- "$p" 2>/dev/null; then changed "removed empty $p"
    else note "kept $p (not empty - something else lives there)"; fi
}

# Is this destination path ours to replace? (section 2.2)
#   0 = ours (or absent). nonzero = refuse, and the caller says why.
# "Ours" means it resolves into this install root, OR into this project's dev
# checkout - deploying over a dev install of the SAME project is a normal
# upgrade, while a link belonging to a DIFFERENT project is the collision this
# check exists to surface at install time rather than as a wrong-verb error six
# months later.
owned_by_us() {
    local link=$1 cur
    [[ -e "$link" || -L "$link" ]] || return 0
    [[ -L "$link" ]] || { warn "$link exists and is NOT a symlink"; return 1; }
    cur=$(readlink -f -- "$link") || return 1
    [[ "$cur" == "$ROOT_REAL"/* ]] && return 0
    # A dev install links into the checkout this script is running from, so
    # $SRC is both necessary and sufficient - and tighter than the old
    # "anywhere under the dev root" test, which adopted links belonging to a
    # DIFFERENT checkout of the same project.
    [[ "$cur" == "$SRC"/* ]] && return 0
    warn "$link -> $cur, which belongs to neither $ROOT_REAL nor $SRC"
    return 1
}

# link <target> <linkname> - idempotent, and honest about which of the three
# things happened.
link_one() {
    local target=$1 link=$2 cur=""
    [[ -e "$target" ]] || die "refusing to link $link -> $target: the target does not exist"
    if [[ -L "$link" ]]; then
        cur="$(readlink -- "$link")"
        if [[ "$cur" == "$target" ]]; then kept "unchanged $link -> $target"; return 0; fi
    fi
    owned_by_us "$link" || die "refusing to take over $link (above). Nothing else was changed."
    ln -sfn -- "$target" "$link"
    if [[ -n "$cur" ]]; then changed "relinked $link -> $target (was $cur)"
    else changed "linked $link -> $target"; fi
}

ensure_dir() {
    local d=$1 mode=$2 why=$3
    if [[ -d "$d" && ! -L "$d" ]]; then
        kept "kept $d (mode 0$(stat -c '%a' -- "$d"), owner $(stat -c '%U' -- "$d"))"
        return 0
    fi
    [[ -L "$d" ]] && die "$d is a symlink. $why  Remove it by hand and re-run."
    install -d -m "$mode" -- "$d"
    changed "created $d (mode $mode)"
}

# ===========================================================================
# .env - read, never written. Only deploy.sh seeds (section 4.2).
# ===========================================================================
# The section 4.1 grammar, in awk: KEY=value, KEY="value", full-line comments
# only, no export, no interpolation. A strict subset of what sh, systemd's
# EnvironmentFile and Python all accept, which is why one file can feed all
# three. Any $ or ` in a value is a refusal, not an expansion.
env_get() {  # env_get <file> <key>  -> value on stdout, empty if absent
    awk -v want="$2" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            eq = index($0, "=");
            if (eq == 0) next;
            k = substr($0, 1, eq - 1); v = substr($0, eq + 1);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k);
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
            if (k != want) next;
            if (length(v) >= 2 && substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"")
                v = substr(v, 2, length(v) - 2);
            val = v;
        }
        END { if (val != "") print val }
    ' "$1"
}

env_lint() {  # env_lint <file> - refuse anything outside the section 4.1 grammar
    local f=$1 n=0 line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        [[ "$line" == *=* ]] || die "$f:$n: not KEY=VALUE"
        k="${line%%=*}"; v="${line#*=}"
        k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "$f:$n: bad key '$k' (section 4.1: ^[A-Z][A-Z0-9_]*\$)"
        [[ "$v" == \"*\" ]] && v="${v:1:${#v}-2}"
        case "$v" in
            *'$'*|*'`'*) die "$f:$n: $k contains \$ or \` - interpolation is not supported (section 4.1). Write the value out in full, or let the consumer join." ;;
        esac
    done < "$f"
}

# ===========================================================================
# uninstall
# ===========================================================================
if [[ $ACTION == uninstall ]]; then
    echo "Uninstalling $PROJECT ($KIND install, $SCOPE scope)"

    # The sentence the operator needs in order not to panic (section 2.4).
    # Ask the LINK TARGET's layout, not this script's: an operator may well be
    # running the deployed installer to tear down links a dev install made.
    _t="$(readlink -f -- "$PKGDIR/index.html" 2>/dev/null || true)"
    if [[ -L "$PKGDIR/index.html" && -n "$_t" ]] \
       && [[ "$(readlink -f -- "${_t%/*}/../payload" 2>/dev/null)" != "${_t%/*}" ]]; then
        echo
        echo "  This is a DEV install: the Cockpit page is symlinks into"
        echo "  ${_t%/*}"
        echo "  Only the symlinks are removed. THE CHECKOUT IS NOT TOUCHED."
        echo
    fi

    # Units first: stop and disable before the file goes, or systemd keeps a
    # removed unit around as failed. Failures are warnings - an uninstall that
    # stops halfway leaves a worse host than one that finishes noisily.
    if ((${#UNITS[@]})); then
        SCTL=(systemctl); [[ "$SCOPE" == user ]] && SCTL=(systemctl --user)
        for u in "${UNITS[@]}"; do
            if [[ -z "$DESTDIR" ]]; then
                "${SCTL[@]}" stop    "$u" >/dev/null 2>&1 || true
                "${SCTL[@]}" disable "$u" >/dev/null 2>&1 || true
            fi
            if [[ -e "$UNITDIR/$u" || -L "$UNITDIR/$u" ]]; then
                rm -f -- "$UNITDIR/$u"; changed "removed $UNITDIR/$u"
            fi
        done
        if [[ -z "$DESTDIR" ]]; then
            "${SCTL[@]}" daemon-reload >/dev/null 2>&1 || true
            "${SCTL[@]}" reset-failed  >/dev/null 2>&1 || true
        fi
    fi

    for f in "${PAGE[@]}"; do remove_link "$PKGDIR/$f"; done
    for h in "${HELPERS[@]}"; do remove_link "$DESTDIR/usr/local/sbin/$h"; done
    remove_dir_if_empty "$PKGDIR"

    [[ -e "$INSTALL_CONF" ]] && { rm -f -- "$INSTALL_CONF"; changed "removed $INSTALL_CONF"; }
    remove_dir_if_empty "$CONFDIR"

    cat <<EOF

KEPT, deliberately - an uninstall removes the software, not your data:
  $ENV_FILE
      Your settings. A reinstall must not make you write them again.
  ${DESTDIR}$(env_get "$ENV_FILE" TUNER_UNDO_DIR 2>/dev/null || echo /var/lib/cockpit-tuner)
      The root-owned undo journal: every setting this plugin ever changed, and
      the value it had before. That is the only record of what was done to this
      machine, and it outlives the tool.
  ~/.local/share/cockpit-tuner/history/   (in every user's own home)
      Snapshot history. Root cannot and must not reach into it.

Cockpit was not restarted. The page disappears from the menu on the next login.
EOF
    printf '\n  %d change(s), %d warning(s)\n' "${#CHANGES[@]}" "${#WARNINGS[@]}"
    exit 0
fi

# ===========================================================================
# pre-flight - every check refuses, and NOTHING is written until all pass
# ===========================================================================
echo "Installing $PROJECT $VERSION"
note "kind:  $KIND    (payload: $SRC)"
note "scope: $SCOPE"
note "env:   $ENV_FILE"
echo
echo "Pre-flight"

if [[ "$SCOPE" == system && -z "$DESTDIR" && $EUID -ne 0 ]]; then
    die "a system-wide install needs root (on this host: submit it to the /srv/jobs runner), or use --user. Nothing was changed."
fi

# --- 1. payload present ----------------------------------------------------
missing=()
for f in "${PAGE[@]}" "${EXTRA[@]}" "$ENVDEFAULT"; do
    [[ -e "$SRC/$f" ]] || missing+=("$f")
done
for h in "${HELPERS[@]}"; do
    [[ -e "$SRC/bin/$h" || -e "$SRC/$h" ]] || missing+=("bin/$h")
done
for l in "${LIBS[@]}"; do
    [[ -e "$SRC/$l" || -e "$SRC/${l#lib/}" ]] || missing+=("$l")
done
for u in "${UNITS[@]}"; do
    [[ -e "$SRC/systemd/$u.in" || -e "$SRC/systemd/$u" ]] || missing+=("systemd/$u")
done
((${#missing[@]} == 0)) \
    || die "the payload is incomplete - missing: ${missing[*]}. Nothing was changed."
note "1. payload complete (${#PAGE[@]} page file(s), ${#EXTRA[@]} payload script(s), ${#UNITS[@]} unit(s))"

# --- 2. the page asks only for what is shipped -----------------------------
# Parsed, not grepped: a regex over HTML is how you miss the one attribute that
# is spelled differently.
python3 - "$SRC/index.html" "${PAGE[@]}" <<'PY' \
    || die "index.html references a file this installer does not ship (above). Nothing was changed."
import html.parser, sys
path, ship = sys.argv[1], set(sys.argv[2:])
refs = []


class Refs(html.parser.HTMLParser):
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "img", "iframe", "audio", "video", "source",
                   "embed", "track") and a.get("src"):
            refs.append((tag, a["src"]))
        elif tag == "link" and a.get("href"):
            refs.append((tag, a["href"]))
        elif tag == "object" and a.get("data"):
            refs.append((tag, a["data"]))


try:
    Refs().feed(open(path, encoding="utf-8").read())
except Exception as e:
    sys.exit("index.html could not be parsed: %s" % type(e).__name__)

local, bad = [], []
for tag, raw in refs:
    u = raw.split("#")[0].split("?")[0].strip()
    if not u:
        continue
    low = u.lower()
    # A scheme, an authority, an absolute path or a parent segment all name
    # something outside this package directory. ../base1/cockpit.js is
    # Cockpit's own file and is deliberately not ours to install.
    if "://" in low or low.startswith(("//", "/", "data:", "mailto:", "../")):
        continue
    if "/" in u:
        bad.append("%s (<%s>: the payload's page level is flat)" % (u, tag))
        continue
    local.append(u)
    if u not in ship:
        bad.append("%s (<%s>)" % (u, tag))
if bad:
    sys.exit("index.html references %s, which PAGE does not install - so the\n"
             "  stale-file sweep DELETES it from the package on every run and Cockpit\n"
             "  answers the browser with an HTML error page. Add it to PAGE, or make\n"
             "  the page stop asking for it." % ", ".join(sorted(set(bad))))
print("  2. index.html: %d package-local reference(s), all shipped (%s)"
      % (len(local), ", ".join(local)))
PY

# --- 2b. and what the JavaScript fetches at RUNTIME ------------------------
# The HTML parse above cannot see this, and for this plugin it is the whole
# risk: app.js does fetchJSON("schemas.json"), so schemas.json is a page file
# even though index.html never mentions it. A payload that shipped it as data
# instead of as a page file would serve a plugin whose every panel is empty.
runtime=$(grep -ohE '(fetch|fetchJSON)\([[:space:]]*"[^"/]+\.[A-Za-z0-9]+"' \
              "${PAGE[@]/#/$SRC/}" 2>/dev/null \
          | sed -E 's/.*"([^"]+)".*/\1/' | sort -u || true)
for r in $runtime; do
    printf '%s\n' "${PAGE[@]}" | grep -qxF "$r" \
        || die "a shipped page file fetches \"$r\" at runtime, which PAGE does not install. Add it to PAGE, or stop fetching it."
done
note "2b. runtime fetch()es resolve to shipped page files ($(echo $runtime | tr ' ' ',' ))"

# --- 3. every helper the page names is shipped and will be linked ----------
# The wg-admin catch, generalised. Comments count: a false positive costs one
# word in an array, a false negative costs a UI with no backend. Bias to
# declaring.
named=$(grep -ohE '/usr/local/sbin/[A-Za-z0-9_.-]+' "${PAGE[@]/#/$SRC/}" 2>/dev/null \
        | sed 's#.*/##' | sort -u || true)
for h in $named; do
    printf '%s\n' "${HELPERS[@]}" | grep -qxF "$h" \
        || die "a shipped page file names /usr/local/sbin/$h, which HELPERS does not install. Add it to HELPERS, or stop the page calling it."
done
note "3. the page names $(printf '%s' "$named" | grep -c . || true) helper(s) under /usr/local/sbin; every one is declared"

# --- 4. (over-declaring a helper is fine; under-declaring is the bug) ------

# --- 5. every unit renders clean, and its ExecStart exists -----------------
# Cleaned with rm -f and rmdir, NOT rm -rf. Nothing in this file recurses: the
# ban in section 2.4 is absolute, and an installer that keeps one "but this one
# is safe" recursion is an installer where the next one is not.
UNIT_TMP="$(mktemp -d)"
cleanup_unit_tmp() { [[ -d "$UNIT_TMP" ]] || return 0
    rm -f -- "$UNIT_TMP"/*; rmdir -- "$UNIT_TMP" 2>/dev/null || true; }
trap cleanup_unit_tmp EXIT
render_unit() {  # render_unit <name> <outfile>
    local in="$SRC/systemd/$1.in" out=$2
    [[ -f "$in" ]] || in="$SRC/systemd/$1"
    [[ -f "$in" ]] || die "missing unit template $SRC/systemd/$1(.in)"
    sed -e "s|@PAYLOAD@|$SRC|g" \
        -e "s|@INSTALL_PATH@|$ROOT|g" \
        -e "s|@ENV_FILE@|$ENV_FILE|g" \
        -e "s|@INSTALL_CONF@|${INSTALL_CONF#"$DESTDIR"}|g" \
        -e "s|@SBIN@|/usr/local/sbin|g" "$in" > "$out"
    # A placeholder that appears nowhere else cannot be silently no-op'ed. This
    # is why the templates use @NAME@ and not a literal old path: sed against a
    # literal succeeds vacuously when the file is edited, and installs a
    # working-looking unit that names a dead path.
    if grep -q '@[A-Z_]\+@' "$out"; then
        local left; left=$(grep -o '@[A-Z_]*@' "$out" | sort -u | tr '\n' ' ')
        rm -f -- "$out"
        die "unrendered placeholder(s) in $1: $left"
    fi
}
for u in "${UNITS[@]}"; do
    render_unit "$u" "$UNIT_TMP/$u"
    # EVERY absolute path on the line, not just the first word: an
    # `ExecStart=/usr/bin/python3 <script>` whose interpreter exists and whose
    # script does not is exactly the unit that installs clean and fails at 03:00.
    while read -r word; do
        [[ "$word" == /* ]] || continue
        [[ -e "$word" ]] || die "$u has ExecStart naming $word, which does not exist. The payload does not ship it."
    done < <(sed -n 's/^ExecStart=[-@+!]*//p' -- "$UNIT_TMP/$u" | tr ' ' '\n')
done
note "5. ${#UNITS[@]} unit(s) render clean; every ExecStart points into the payload"

# --- 6. .envdefault parses, and declares every required key ----------------
env_lint "$SRC/$ENVDEFAULT"
for k in "${REQUIRED_ENV[@]}"; do
    grep -qE "^[[:space:]]*$k=" "$SRC/$ENVDEFAULT" \
        || die "$ENVDEFAULT does not declare REQUIRED_ENV key $k."
done
note "6. $ENVDEFAULT parses and declares all ${#REQUIRED_ENV[@]} required key(s)"

# --- 7. .env exists and defines every required key, non-empty --------------
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ "$KIND" == dev ]]; then
        die "no $ENV_FILE. A dev install reads the checkout's TEST-ONLY .env:
    cp $SRC/$ENVDEFAULT $SRC/.env   # then edit it
  Nothing was changed."
    fi
    die "no $ENV_FILE. Run deploy.sh, which seeds it from $ENVDEFAULT (missing-only). Nothing was changed."
fi
env_lint "$ENV_FILE"
for k in "${REQUIRED_ENV[@]}"; do
    v="$(env_get "$ENV_FILE" "$k")"
    [[ -n "$v" ]] || die "$ENV_FILE does not set $k (or sets it empty). See $SRC/$ENVDEFAULT for what it means. Nothing was changed."
done
TUNER_HISTORY_DIR="$(env_get "$ENV_FILE" TUNER_HISTORY_DIR)"
TUNER_UNDO_DIR="$(env_get "$ENV_FILE" TUNER_UNDO_DIR)"
note "7. $ENV_FILE defines all ${#REQUIRED_ENV[@]} required key(s)"

# --- 8. nothing declared collides with another project --------------------
for f in "${PAGE[@]}"; do
    owned_by_us "$PKGDIR/$f" || die "$PKGDIR/$f belongs to something else (above). Nothing was changed."
done
for h in "${HELPERS[@]}"; do
    owned_by_us "$DESTDIR/usr/local/sbin/$h" || die "/usr/local/sbin/$h belongs to something else (above). Nothing was changed."
done
note "8. every destination is free, or is already ours"

# --- 9. no dev-tree and no retired path in anything being shipped ---------
# This one check, had it existed, would have caught all thirteen occurrences of
# the retired path in samba-ad-lab, including the two that are broken today.
# $SELF is scanned too. That carve-out used to exist because this installer
# carried a DEV_ROOT= literal; classification is by layout now, so the only
# occurrence left is the split pattern on the grep line below, which cannot
# match itself. An audit with a permanent exemption is one nobody reruns.
# README.md and LICENSE are shipped too, so they are scanned too. A README
# that documents "how do I tell a dev install from a deployed one" is exactly
# the file most likely to name the dev root, and it lands on production hosts
# like any other artifact.
scan=("${PAGE[@]/#/$SRC/}" "${EXTRA[@]/#/$SRC/}" "$SRC/$ENVDEFAULT" "$SELF")
for d in README.md LICENSE; do [[ -f "$SRC/$d" ]] && scan+=("$SRC/$d"); done
for u in "${UNITS[@]}"; do
    [[ -f "$SRC/systemd/$u.in" ]] && scan+=("$SRC/systemd/$u.in")
    [[ -f "$SRC/systemd/$u" ]]    && scan+=("$SRC/systemd/$u")
done
# BOTH patterns are split so this grep line cannot match itself now that $SELF
# is in the scan set. Splitting a scanner's own pattern weakens nothing: the
# concatenation it searches for is unchanged, and every OTHER file is still
# matched in full. It only stops the audit reporting itself, which is what let
# the carve-out exist.
if hits=$(grep -RIn -e "/opt/sc""/git" -e "/srv/smb/share/sc/ai-orchestrator""-group" -- "${scan[@]}" 2>/dev/null); then
    printf '%s\n' "$hits" | sed 's/^/        /' >&2
    die "a shipped file hardcodes a dev or retired path (above). It belongs in .env. Nothing was changed."
fi
note "9. no shipped file names a dev-tree or retired path"

# In a dev install the payload is the group-writable share. Say so out loud;
# it is a fact about a dev install, not a defect, and an operator who has
# forgotten which kind of install this host is running needs the sentence.
if [[ "$KIND" == dev ]]; then
    warn "DEV INSTALL: every link below points into $SRC, which may be group-writable and disappears if that tree is unmounted. This is what a dev install IS. Deploy with deploy.sh for a self-sustaining host."
fi

echo
echo "Installing"

# ===========================================================================
# 1. the Cockpit page - a REAL directory of per-file symlinks (section 2.1)
# ===========================================================================
# NOT one directory symlink at $SRC. install.sh is the same script in a dev
# install, and there $SRC is the checkout: a directory symlink would point
# Cockpit's WEB ROOT at .git/, and serve it over HTTPS to any authenticated
# session.
ensure_dir "$PKGDIR" 0755 "Cockpit serves this directory to every logged-in session."
for f in "${PAGE[@]}"; do link_one "$SRC/$f" "$PKGDIR/$f"; done

# Sweep anything a previous version left. Everything here is a symlink, so
# remove_link cannot recurse into the payload even if one of them points there.
shopt -s nullglob
for existing in "$PKGDIR"/*; do
    base="$(basename -- "$existing")"
    keep=0
    for f in "${PAGE[@]}"; do [[ "$base" == "$f" ]] && keep=1; done
    ((keep)) || { remove_link "$existing"; }
done
shopt -u nullglob

# ===========================================================================
# 2. helpers and libs - this plugin declares none; the loops still exist so
#    plugin number seven only has to fill the arrays in.
# ===========================================================================
if ((${#HELPERS[@]})); then
    ensure_dir "$DESTDIR/usr/local/sbin" 0755 "it holds root-run helpers."
    for h in "${HELPERS[@]}"; do
        t="$SRC/bin/$h"; [[ -e "$t" ]] || t="$SRC/$h"   # JC-5: bin/ in the payload, root in a checkout
        link_one "$t" "$DESTDIR/usr/local/sbin/$h"
    done
fi

# ===========================================================================
# 3. state the plugin writes, outside the payload so an upgrade cannot eat it
# ===========================================================================
# The undo journal is the only record of what this plugin changed on this
# machine. It lives in /var/lib because backup policy, logrotate and
# restorecon already know that tree; they do not know /opt/<project>/state.
# adapter.js creates it on first write, so this is not load-bearing - but a
# directory that first appears the moment somebody edits a sysctl is a
# directory nobody has ever looked at.
if [[ "$SCOPE" == system ]]; then
    ensure_dir "$DESTDIR$TUNER_UNDO_DIR" 0755 "it holds the root-owned undo journal."
fi

# ===========================================================================
# 4. units - RENDERED AND PLACED. Never enabled, never started (section 6.1)
# ===========================================================================
# A dev install refuses to render units at all without --with-timer, because a
# developer running this from the share while a deployed install of the same
# project runs on the same host would otherwise get two snapshot timers writing
# the same history directory from two different payloads.
if ((WITH_TIMER)); then
    ensure_dir "$UNITDIR" 0755 "systemd reads user units from here."
    for u in "${UNITS[@]}"; do
        render_unit "$u" "$UNIT_TMP/$u"
        if [[ -f "$UNITDIR/$u" ]] && cmp -s -- "$UNIT_TMP/$u" "$UNITDIR/$u"; then
            kept "unchanged $UNITDIR/$u"
        else
            install -m 0644 -- "$UNIT_TMP/$u" "$UNITDIR/$u"
            changed "rendered $UNITDIR/$u"
        fi
    done
    if [[ -z "$DESTDIR" ]]; then
        if [[ "$SCOPE" == user ]]; then systemctl --user daemon-reload || true
        else systemctl daemon-reload || true; fi
    fi
    note "units placed, NOT enabled and NOT started - that is the operator's decision"
elif ((${#UNITS[@]})); then
    note "units not rendered (pass --with-timer). ${#UNITS[@]} template(s) available"
fi

# ===========================================================================
# 5. install.conf - the machine's record. .env is the operator's; this is not.
# ===========================================================================
ensure_dir "$CONFDIR" 0755 "it holds this install's record."
tmp_conf="$(mktemp)"
cat > "$tmp_conf" <<EOF
# Written by install.sh. Do not edit; re-run install.sh instead.
INSTALL_KIND=$KIND
INSTALL_SCOPE=$SCOPE
INSTALL_PATH=$ROOT
PAYLOAD=$SRC
ENV_FILE=$ENV_FILE
PKGDIR=${PKGDIR#"$DESTDIR"}
UNITDIR=${UNITDIR#"$DESTDIR"}
VERSION=$VERSION
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INSTALLED_BY=install.sh
EOF
if [[ -f "$INSTALL_CONF" ]] && diff -q <(grep -v '^INSTALLED_AT=' "$tmp_conf") \
        <(grep -v '^INSTALLED_AT=' "$INSTALL_CONF") >/dev/null 2>&1; then
    kept "unchanged $INSTALL_CONF"
    rm -f -- "$tmp_conf"
else
    install -m 0644 -- "$tmp_conf" "$INSTALL_CONF"; rm -f -- "$tmp_conf"
    changed "wrote $INSTALL_CONF"
fi

# ===========================================================================
# 6. post-install assertion - what was PRODUCED, not what was intended
# ===========================================================================
# Separate from the pre-flight on purpose: a script that only checked its own
# intentions would report the mode it meant to set, in both places.
echo
echo "Verifying"
fail=0
shopt -s nullglob
found=("$PKGDIR"/*)
shopt -u nullglob
if ((${#found[@]} != ${#PAGE[@]})); then
    warn "$PKGDIR holds ${#found[@]} entries; PAGE declares ${#PAGE[@]}"; fail=1
fi
for f in "${PAGE[@]}"; do
    l="$PKGDIR/$f"
    [[ -L "$l" ]]                            || { warn "$l is not a symlink"; fail=1; continue; }
    t="$(readlink -f -- "$l" 2>/dev/null || true)"
    [[ -n "$t" && -e "$t" ]]                 || { warn "$l is a DANGLING symlink"; fail=1; continue; }
    [[ "$t" == "$(readlink -f -- "$SRC")"/* ]] || { warn "$l -> $t, which is outside the payload"; fail=1; }
done
for h in "${HELPERS[@]}"; do
    l="$DESTDIR/usr/local/sbin/$h"
    [[ -L "$l" && -x "$(readlink -f -- "$l")" ]] || { warn "$l is not a symlink to an executable"; fail=1; }
done
conf_payload="$(env_get "$INSTALL_CONF" PAYLOAD)"
[[ "$(readlink -f -- "$conf_payload")" == "$(readlink -f -- "$SRC")" ]] \
    || { warn "install.conf PAYLOAD=$conf_payload does not resolve to $SRC"; fail=1; }
((fail)) || note "the installed tree is exactly ${#PAGE[@]} symlink(s), every one resolving into $SRC"

# ===========================================================================
# 7. what changed, and what the operator does next
# ===========================================================================
echo
echo "Summary"
printf '  %d change(s), %d unchanged, %d warning(s)\n' \
    "${#CHANGES[@]}" "${#KEPT[@]}" "${#WARNINGS[@]}"
if ((${#WARNINGS[@]})); then
    echo
    echo "  Action required:"
    for w in "${WARNINGS[@]}"; do printf '    ! %s\n' "$w"; done
fi

cat <<EOF

Next steps
  1. Reload Cockpit in the browser (Ctrl-Shift-R); log out and back in for the
     menu entry. Cockpit was NOT restarted and cockpit.socket was not touched.
  2. Which install is this? One command, every plugin on the host. It asks
     the LAYOUT (is the page directory the target of a sibling "payload"
     symlink?), so it needs no path literal and stays right if a tree moves:
       for d in /usr/share/cockpit/*/; do n=\${d%/}; n=\${n##*/};
         t=\$(readlink -f "\$d/index.html" 2>/dev/null) || continue; s=\${t%/*}
         if [ "\$(readlink -f "\$s/../payload" 2>/dev/null)" = "\$s" ]
           then k="deployed"; else k="DEV (checkout)"; fi
         printf '%-12s %-14s %s\n' "\$n" "\$k" "\$t"; done
  3. The snapshot timer is per-user and is NOT enabled by this script. In the
     session that should collect snapshots, and only there:
       systemctl --user enable --now cockpit-tuner-snapshot.timer
     Snapshots land in $TUNER_HISTORY_DIR; nothing is written when nothing changed.
EOF
exit 0
