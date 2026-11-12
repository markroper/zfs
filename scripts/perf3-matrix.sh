#!/bin/bash
# Linux: slog ZTS with priming forced on and ztest, then the new perf workloads.
cd /var/tmp/zt
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
sed -e 's|^B=/var/tmp/b-dbg-prefetch$|B=/var/tmp/b-dbg-all|' zts-prime.sh > zts-prime-all.sh; chmod +x zts-prime-all.sh
./zts-prime-all.sh /var/tmp/b-dbg-all slog > ztsp-all.log 2>&1
echo "=== perf3"
for wl in create remove rename truncate clone; do
  rm -rf /var/tmp/img-$wl
  ./perf2.sh gen /var/tmp/b-rel-base $wl /var/tmp/img-$wl || exit 1
done
for r in 1 2 3; do
  for wl in create remove rename truncate clone write link; do
    [ $wl = write ] || [ $wl = link ] || ./perf2.sh run /var/tmp/b-rel-base 0 base /var/tmp/img-$wl delay:23
    [ $wl = write ] || [ $wl = link ] || ./perf2.sh run /var/tmp/b-rel-prefetch 1 prefetch-v1 /var/tmp/img-$wl delay:23
    ./perf2.sh run /var/tmp/b-rel-all 1 prefetch-all /var/tmp/img-$wl delay:23
  done
done
