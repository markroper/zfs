#!/bin/bash
# usage (as root): zts.sh <build-dir> <tags>
B=$1 TAGS=$2
cd $B
scripts/zfs.sh -u >/dev/null 2>&1
scripts/zfs-helpers.sh -iv >/dev/null 2>&1
scripts/zfs.sh || { echo LOAD-FAIL; exit 1; }
chmod -R a+rX $B
su ubuntu -c "cd $B && scripts/zfs-tests.sh -T $TAGS" > $B/zts-$TAGS.log 2>&1
grep -E '^Results Summary|^PASS|^FAIL|^SKIP|^KILLED|^Running Time|^Percent' -A0 $B/zts-$TAGS.log
grep -E '\[(FAIL|KILLED)\]' $B/zts-$TAGS.log | head -20
grep -E 'slog_replay_prime_race' $B/zts-$TAGS.log | head
