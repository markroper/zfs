#!/bin/bash
# Build the review fixes, run the prime tests, then a minimal perf retest.
cd /var/tmp/zt
./build-patch.sh dbg-rev2 fork/zil-prime-arc /var/tmp/zt/rev2.patch debug || exit 1
./build-patch.sh rel-rev2 fork/zil-prime-arc /var/tmp/zt/rev2.patch release || exit 1
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
(cd /var/tmp/b-dbg-rev2 && nice make checkstyle > cs.log 2>&1; echo "CHECKSTYLE rc=$?")
./newtests-rev2.sh
echo "=== perf-rev"
for wl in write create remove rename truncate clone link; do
  ./perf2.sh run /var/tmp/b-rel-rev2 1 rev /var/tmp/img-$wl delay:23
done
