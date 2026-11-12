#!/bin/bash
# Rebuild the TX_WRITE image with spread-out writes, then replay all variants.
cd /var/tmp/zt
SC1=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0af627857d03639c4
while pgrep -f "[p]erf2.sh run /var" >/dev/null; do sleep 5; done
variants() {
  ./perf2.sh run /var/tmp/b-rel-base 0 base $1 $2
  ./perf2.sh run /var/tmp/b-rel-port 0 port-off $1 $2
  ./perf2.sh run /var/tmp/b-rel-port 1 port $1 $2
  ./perf2.sh run /var/tmp/b-rel-prefetch 1 prefetch $1 $2
}
rm -rf /var/tmp/img-write
./perf2.sh gen /var/tmp/b-rel-base write /var/tmp/img-write || exit 1
for r in 1 2 3; do
  for wl in write link; do variants /var/tmp/img-$wl delay:23; done
done
for wl in write link; do variants /var/tmp/img-$wl dev:$SC1; done
