#!/bin/bash
# Continue the matrix with the setattr fix (b-rel-all2) as prefetch-all.
cd /var/tmp/zt
while pgrep -f "[p]erf2.sh run /var" >/dev/null; do sleep 5; done
echo "=== perf4 (prefetch-all = rel-all2)"
./perf2.sh run /var/tmp/b-rel-all2 1 prefetch-all /var/tmp/img-truncate delay:23
for r in 2 3; do
  for wl in create remove rename truncate clone write link; do
    [ $wl = write ] || [ $wl = link ] || ./perf2.sh run /var/tmp/b-rel-base 0 base /var/tmp/img-$wl delay:23
    [ $wl = write ] || [ $wl = link ] || ./perf2.sh run /var/tmp/b-rel-prefetch 1 prefetch-v1 /var/tmp/img-$wl delay:23
    ./perf2.sh run /var/tmp/b-rel-all2 1 prefetch-all /var/tmp/img-$wl delay:23
  done
done
./perf2.sh run /var/tmp/b-rel-all2 1 prefetch-all /var/tmp/img-write delay:23
./perf2.sh run /var/tmp/b-rel-all2 1 prefetch-all /var/tmp/img-link delay:23
