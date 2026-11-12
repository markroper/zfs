#!/bin/bash
# Build and test the taskq/name changes on top of the fork head, then minimal perf.
cd /var/tmp/zt
./build-patch.sh dbg-r3 fork/zil-prime-arc /var/tmp/zt/r3.patch debug || exit 1
./build-patch.sh rel-r3 fork/zil-prime-arc /var/tmp/zt/r3.patch release || exit 1
(cd /var/tmp/b-dbg-r3 && make checkstyle > cs.log 2>&1; echo "CHECKSTYLE rc=$?")
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
sed -e 's|^B=.*|B=/var/tmp/b-dbg-r3|' newtests-final.sh > newtests-r3.sh; chmod +x newtests-r3.sh; ./newtests-r3.sh
for t in volume fs heal race; do grep -hE "Test:.*slog_replay_prime_$t" new-slog_replay_prime_$t.log | sed 's/.*functional\/slog\///'; done
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
./zts-prime.sh /var/tmp/b-dbg-r3 slog
echo "=== perf"
for wl in write link create remove rename truncate clone; do ./perf2.sh run /var/tmp/b-rel-r3 1 r3 /var/tmp/img-$wl delay:23; done
echo R3-DONE
