#!/bin/bash
# Build the review fixes, run the prime tests, then a minimal perf retest.
cd /var/tmp/zt
./build-patch.sh dbg-rev fork/zil-prime-arc /var/tmp/zt/rev.patch debug || exit 1
./build-patch.sh rel-rev fork/zil-prime-arc /var/tmp/zt/rev.patch release || exit 1
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
./newtests-rev.sh
echo "=== perf-rev"
for wl in write create remove rename truncate clone link; do
  ./perf2.sh run /var/tmp/b-rel-rev 1 rev /var/tmp/img-$wl delay:23
done
