#!/bin/bash
# Replay benchmark that builds the ZIL once on fast storage, then replays the
# identical pool image from a slow device for each variant.
#
#   perf2.sh gen <build-dir> <write|link> <img-dir>
#   perf2.sh run <build-dir> <prime 0|1> <label> <img-dir> <delay:MS|dev:/dev/X>
#   perf2.sh lat <dev>        # report random 16K read latency at QD1
set -u
ulimit -n 65536
P=perfpool
MAIN_SZ=12G
SLOG_SZ=1G
WORK=/var/tmp/zwork

load() {
	cd $1
	scripts/zfs.sh -u >/dev/null 2>&1; modprobe -r zfs 2>/dev/null
	scripts/zfs.sh >/dev/null 2>&1 || { echo LOAD-FAIL; exit 1; }
	test -f /sys/module/zfs/parameters/zfs_txg_timeout || { echo NO-MODULE; exit 1; }
	echo 1 > /sys/module/zfs/parameters/zfs_bclone_enabled
}
WL_PY=/var/tmp/zt/perf2-wl.py

teardown() {
	$1/zpool export $P >/dev/null 2>&1
	$1/zpool destroy -f $P >/dev/null 2>&1
	dmsetup remove zslow >/dev/null 2>&1
	losetup -D
}

case $1 in
gen)
	B=$2 WL=$3 IMG=$4
	load $B; teardown $B
	mkdir -p $IMG; rm -f $IMG/main.img $IMG/slog.img
	truncate -s $MAIN_SZ $IMG/main.img; truncate -s $SLOG_SZ $IMG/slog.img
	# Use a loop device so the label records a disk vdev, which can then
	# be replayed from any block device.
	GLOOP=$(losetup -f --show $IMG/main.img)
	$B/zpool create -f -o ashift=12 -O recordsize=128k -O compression=off \
	    -O atime=off $P $GLOOP log $IMG/slog.img
	$B/zfs create $P/fs
	D=/$P/fs
	if [ $WL = write ]; then
		fio --name=lay --directory=$D --nrfiles=2000 --filesize=1m \
		    --bs=128k --rw=write --ioengine=psync --openfiles=2000 \
		    --output=/dev/null >/dev/null || { echo LAYOUT-FAIL; exit 1; }
	elif [ $WL = link ]; then
		python3 - $D <<'PY'
import os, sys
d = sys.argv[1]; os.mkdir(d + "/a"); os.mkdir(d + "/b")
for i in range(200000):
    os.close(os.open("%s/a/f%d" % (d, i), os.O_CREAT | os.O_WRONLY, 0o644))
PY
	else
		python3 $WL_PY layout $WL $D || { echo LAYOUT-FAIL; exit 1; }
	fi
	sync; $B/zpool sync $P
	dd if=/dev/urandom of=$D/zilhdr bs=4k count=1 conv=fsync status=none
	$B/zpool freeze $P
	if [ $WL = write ]; then
		# 8192 O_DSYNC 4 KiB writes at random 4 KiB offsets in random
		# files, so most records partially overwrite a distinct block.
		python3 - $D <<'PY' || { echo RMW-FAIL; exit 1; }
import os, sys, random, glob
d = sys.argv[1]; random.seed(2)
files = sorted(glob.glob(d + "/lay.*"))
assert len(files) == 2000, len(files)
fds = [os.open(f, os.O_WRONLY | os.O_DSYNC) for f in files]
blocks = set()
for _ in range(8192):
    i = random.randrange(len(fds)); off = random.randrange(256) * 4096
    os.pwrite(fds[i], os.urandom(4096), off)
    blocks.add((i, off // 131072))
print("WRITES distinct_files=%d distinct_blocks=%d" %
    (len({b[0] for b in blocks}), len(blocks)))
PY
	elif [ $WL != link ]; then
		python3 $WL_PY ops $WL $D || { echo OPS-FAIL; exit 1; }
	else
		python3 - $D <<'PY'
import os, sys, random
d = sys.argv[1]; random.seed(1)
for n, i in enumerate(random.sample(range(200000), 10000)):
    os.link("%s/a/f%d" % (d, i), "%s/b/l%d" % (d, n))
fd = os.open(d + "/b", os.O_RDONLY); os.fsync(fd); os.close(fd)
PY
	fi
	if [ $WL = write ] || [ $WL = link ]; then
		( cd $D && find . -type f | sort | xargs -r sha256sum ) | sha256sum | awk '{print $1}' > $IMG/expected.sum
	else
		python3 $WL_PY sum $D > $IMG/expected.sum; touch $IMG/pysum
	fi
	$B/zfs unmount $D
	$B/zpool export $P
	NREC=$($B/zdb -e -p $GLOOP -p $IMG -iv $P/fs 2>/dev/null | grep -cE '^ *TX_')
	losetup -d $GLOOP
	echo "GEN-OK wl=$WL records=$NREC sum=$(cat $IMG/expected.sum)"
	;;
run)
	B=$2 PRIME=$3 LABEL=$4 IMG=$5 TGT=$6
	load $B; teardown $B
	if [ $PRIME = 1 ]; then
		echo 1 > /sys/module/zfs/parameters/zfs_zil_replay_prime_arc || { echo NO-PARAM; exit 1; }
	fi
	rm -rf $WORK; mkdir -p $WORK
	cp --sparse=always $IMG/slog.img $WORK/slog.img
	SECT=$(( $(stat -c %s $IMG/main.img) / 512 ))
	case $TGT in
	delay:*)
		cp --sparse=always $IMG/main.img $WORK/main.img
		LOOP=$(losetup -f --show $WORK/main.img)
		dmsetup create zslow --table "0 $SECT delay $LOOP 0 ${TGT#delay:} $LOOP 0 0"
		;;
	dev:*)
		DEV=$(readlink -f ${TGT#dev:})
		dmsetup create zslow --table "0 $SECT linear $DEV 0"
		dd if=$IMG/main.img of=/dev/mapper/zslow bs=16M oflag=direct \
		    conv=sparse,fsync status=none
		;;
	esac
	sync; echo 3 > /proc/sys/vm/drop_caches
	echo 0 > /proc/spl/kstat/zfs/dbgmsg
	R0=$(awk '{print $1}' /sys/block/$(basename $(readlink -f /dev/mapper/zslow))/stat)
	T0=$(date +%s.%N)
	$B/zpool import -f -d /dev/mapper -d $WORK $P || { echo IMPORT-FAIL; exit 1; }
	T1=$(date +%s.%N)
	R1=$(awk '{print $1}' /sys/block/$(basename $(readlink -f /dev/mapper/zslow))/stat)
	if [ -f $IMG/pysum ]; then
		SUM=$(python3 $WL_PY sum /$P/fs)
	else
		SUM=$( (cd /$P/fs && find . -type f | sort | xargs -r sha256sum) | sha256sum | awk '{print $1}')
	fi
	[ "$SUM" = "$(cat $IMG/expected.sum)" ] && OK=match || OK=MISMATCH
	ERR=$(dmesg | tail -100 | grep -c 'replay transaction error')
	printf "RESULT wl=$(basename $IMG) label=%s tgt=%s prime=%s import_s=%.2f slow_reads=%s data=%s replay_errors=%s\n" \
	    $LABEL $TGT $PRIME $(echo "$T1 - $T0" | bc) $((R1 - R0)) $OK $ERR
	teardown $B
	;;
lat)
	DEV=$(readlink -f $2)
	fio --name=lat --filename=$DEV --rw=randread --bs=16k --iodepth=1 \
	    --direct=1 --ioengine=psync --runtime=30 --time_based --size=4g \
	    --readonly --output-format=json 2>/dev/null | python3 -c '
import json, sys
j = json.load(sys.stdin)["jobs"][0]["read"]
p = j["clat_ns"]["percentile"]
print("LAT iops=%.0f mean_ms=%.2f p50_ms=%.2f p99_ms=%.2f" % (j["iops"],
    j["clat_ns"]["mean"] / 1e6, p["50.000000"] / 1e6, p["99.000000"] / 1e6))'
	;;
esac
