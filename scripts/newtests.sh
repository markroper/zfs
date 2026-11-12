#!/bin/bash
B=/var/tmp/b-dbg-prefetch
cd $B
scripts/zfs.sh -u >/dev/null 2>&1; modprobe -r zfs 2>/dev/null; scripts/zfs-helpers.sh -iv >/dev/null 2>&1; scripts/zfs.sh || { echo LOAD-FAIL; exit 1; }
test -f /sys/module/zfs/parameters/zfs_zil_replay_prime_arc || { echo WRONG-MODULE; exit 1; }
chown -R ubuntu $B/tests/zfs-tests/bin
chmod -R a+rX $B; rm -f /var/tmp/file-vdev* /var/tmp/tunable-*
for t in slog_replay_prime_volume slog_replay_prime_fs slog_replay_prime_heal slog_replay_prime_race; do
  su ubuntu -c "cd $B && scripts/zfs-tests.sh -t $B/tests/zfs-tests/tests/functional/slog/$t.ksh" > /var/tmp/zt/new-$t.log 2>&1
  sleep 2; echo "$t: $(grep -E '^Test:.*\[(PASS|FAIL|KILLED|SKIP)\]' /var/tmp/zt/new-$t.log | grep -oE '\[(PASS|FAIL|KILLED|SKIP)\]' | tail -1)"
done
