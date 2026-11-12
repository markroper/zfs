#!/bin/bash
# usage: perf.sh <build-dir> <prime 0|1> <label> <workload write|link> <read-delay-ms|dev:/path>
set -u
ulimit -n 16384
B=$1 PRIME=$2 LABEL=$3 WL=$4 DELAY=$5
P=perfpool
cd $B
ZP=$B/zpool ZF=$B/zfs
cleanup() {
  $ZP destroy -f $P >/dev/null 2>&1
  dmsetup remove zdelay >/dev/null 2>&1
  losetup -D
  rm -f /var/tmp/perf.img /var/tmp/slog.img
}
cleanup
scripts/zfs.sh -u >/dev/null 2>&1; scripts/zfs.sh >/dev/null 2>&1 || { echo LOAD-FAIL; exit 1; }
if [ $PRIME = 1 ]; then echo 1 > /sys/module/zfs/parameters/zfs_zil_replay_prime_arc || { echo NO-PARAM; exit 1; }; fi
truncate -s 16G /var/tmp/perf.img; truncate -s 4G /var/tmp/slog.img
LOOP=$(losetup -f --show /var/tmp/perf.img)
SLOG=$(losetup -f --show /var/tmp/slog.img)
if [[ $DELAY == dev:* ]]; then
  MAIN=${DELAY#dev:}
  wipefs -aq $MAIN
else
  SECT=$(blockdev --getsz $LOOP)
  dmsetup create zdelay --table "0 $SECT delay $LOOP 0 $DELAY $LOOP 0 0"
  MAIN=/dev/mapper/zdelay
fi
$ZP create -f -o ashift=12 -O recordsize=${RS:-128k} -O compression=off -O atime=off $P $MAIN log $SLOG
$ZF create $P/fs
D=/$P/fs
if [ $WL = write ]; then
  fio --name=lay --directory=$D --nrfiles=2000 --filesize=${FS:-1m} --bs=${RS:-128k} --rw=write --ioengine=psync --openfiles=64 --output=/dev/null >/dev/null
  sync; $ZP sync $P
  dd if=/dev/urandom of=$D/zilprime bs=4k count=1 conv=fsync status=none
  $ZP freeze $P
  fio --name=rmw --directory=$D --nrfiles=2000 --filesize=${FS:-1m} --bs=4k --rw=randwrite --sync=1 --ioengine=psync --io_size=32m --file_service_type=random --openfiles=2000 --output=/dev/null >/dev/null
else
  python3 - $D create <<'PY'
import os, sys
d = sys.argv[1]; os.mkdir(d + "/a"); os.mkdir(d + "/b")
for i in range(200000):
    os.close(os.open("%s/a/f%d" % (d, i), os.O_CREAT | os.O_WRONLY, 0o644))
PY
  sync; $ZP sync $P
  dd if=/dev/urandom of=$D/zilprime bs=4k count=1 conv=fsync status=none
  $ZP freeze $P
  python3 - $D link <<'PY'
import os, sys, random
d = sys.argv[1]; random.seed(1)
for n, i in enumerate(random.sample(range(200000), 10000)):
    os.link("%s/a/f%d" % (d, i), "%s/b/l%d" % (d, n))
fd = os.open(d + "/b", os.O_RDONLY); os.fsync(fd); os.close(fd)
PY
fi
NREC=$($B/zdb -iv $P/fs 2>/dev/null | grep -cE 'TX_WRITE|TX_LINK')
$ZP export $P
echo 3 > /proc/sys/vm/drop_caches
echo 0 > /proc/spl/kstat/zfs/dbgmsg
DM=$(basename $(readlink -f $MAIN)); R0=$(awk '{print $1}' /sys/block/$DM/stat)
T0=$(date +%s.%N)
$ZP import -d $(dirname $MAIN) -d /dev $P
T1=$(date +%s.%N)
R1=$(awk '{print $1}' /sys/block/$DM/stat)
NL=$(ls /$P/fs/b 2>/dev/null | wc -l)
ERR=$(dmesg | tail -50 | grep -c 'replay transaction error')
printf "RESULT label=%s wl=%s delay=%sms prime=%s records=%s import_s=%.2f links=%s replay_errors=%s main_reads=%s\n" $LABEL $WL $DELAY $PRIME $NREC $(echo "$T1 - $T0" | bc) $NL $ERR $((R1-R0))
cleanup
