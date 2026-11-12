#!/bin/bash
# usage (as root): zts-prime.sh <build-dir> <tags>  -- ZTS with priming forced on
B=$1 TAGS=$2
cd $B
scripts/zfs.sh -u >/dev/null 2>&1
scripts/zfs-helpers.sh -iv >/dev/null 2>&1
scripts/zfs.sh || { echo LOAD-FAIL; exit 1; }
test -f /sys/module/zfs/parameters/zfs_zil_replay_prime_arc || { echo WRONG-MODULE; exit 1; }
echo 1 > /sys/module/zfs/parameters/zfs_zil_replay_prime_arc
chmod -R a+rX $B; rm -f /var/tmp/file-vdev* /var/tmp/tunable-*
su ubuntu -c "cd $B && scripts/zfs-tests.sh -T $TAGS" > $B/zts-prime-$TAGS.log 2>&1
echo "prime_arc at end: $(cat /sys/module/zfs/parameters/zfs_zil_replay_prime_arc)"
grep -E '^PASS|^FAIL|^SKIP|^KILLED|^Percent' $B/zts-prime-$TAGS.log
grep -E '\[(FAIL|KILLED)\]' $B/zts-prime-$TAGS.log | head -20
dmesg | grep -c 'replay transaction error'
mkdir -p /var/tmp/ztest-prime && cd /var/tmp/ztest-prime && rm -rf ./*
$B/ztest -V -T 300 -f /var/tmp/ztest-prime -o zfs_zil_replay_prime_arc=1 > ztest.log 2>&1 && echo ZTEST-OK || { echo ZTEST-FAILED; tail -20 ztest.log; }
