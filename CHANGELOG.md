# Changelog

## 1.1.0 - 2026-11-16

Conntrack tunables, after edt1 lost all networking 2026-11-14 08:25 to 11-15
20:22 when nf_conntrack hit its 262144 max and dropped every new flow (a leak
of idle ESTABLISHED connections to :8444 held slots for the 5-day timeout).

- New settings (76 -> 80): `net.netfilter.nf_conntrack_max` (editable, range
  65536-4194304, recommended 1048576 on edt1), `net.netfilter.nf_conntrack_tcp_timeout_established`
  (editable, range 3600-432000, recommended 86400), and read-only info rows
  `nf_conntrack_count` and `nf_conntrack_buckets`.
- Descriptions note that net.netfilter.* exists only with the nf_conntrack
  module loaded (persist with /etc/modules-load.d/nf_conntrack.conf) and that
  the tuner's 95-cockpit-tuner.conf sorts after other sysctl.d files.
- `stability-safe` profile gains max=1048576 and established=86400.
- No reader change needed: a missing /proc file already resolves to an empty
  value in both app.js and bin/tuner-snapshot.py.

## 1.0.1 - 2026-09-07

Install classification is now decided by LAYOUT, not by a development-root path
prefix, and this plugin was deployed to its real install path on edt1.

- `install.sh` decides dev vs deployed by asking whether its own directory is
  what a sibling `payload` symlink resolves to. The old test compared `$SRC`
  against a hardcoded development root and got a checkout sitting ANYWHERE ELSE
  wrong: such a checkout classified itself `deployed`, so it skipped the
  group-writable warning, wrote INSTALL_KIND=deployed for a host that was not
  self-sustaining, and dropped "the checkout is not touched" from
  `--uninstall`. Reproduced before the change and confirmed fixed after.
- Because that literal is gone, pre-flight check 9 now scans `install.sh`
  itself. The carve-out that exempted it is removed. Both of the check's own
  patterns are split so the scanner cannot match itself; the string it searches
  for is unchanged, so nothing is weakened.
- `owned_by_us` recognises a dev link by `$SRC` rather than by "anywhere
  under the development root", which is tighter: it no longer adopts a link
  belonging to a different checkout of the same project.
- The uninstall notice and the dev warning ask the LINK TARGET's layout, so
  they stay correct when the deployed installer tears down links a dev install
  made.
- Fixed: backticks inside the Next-steps heredoc were command substitution, so
  the installer ran `payload` as a command and printed a mangled hint.
- The stale user-scope copy at ~/.local/share/cockpit/tuner (which SHADOWED the
  system install for that user) is now symlinks into the deployed payload.
A recursive grep of the deployed tree for the development root or the retired
checkout path now returns nothing at all.
