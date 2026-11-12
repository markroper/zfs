#!/bin/sh
exec > /var/log/zbuild.log 2>&1
say() { echo "ZTEST: $*"; echo "ZTEST: $*" > /dev/console; }
say start
grep -q nameserver /etc/resolv.conf || echo "nameserver 169.254.169.253" > /etc/resolv.conf
export ASSUME_ALWAYS_YES=yes
n=0; until pkg bootstrap -f >/tmp/pkgboot.log 2>&1; do
  n=$((n+1))
  if [ $n -gt 20 ]; then
    say no-network; (ifconfig -a; netstat -rn; cat /etc/resolv.conf; tail -5 /tmp/pkgboot.log; fetch -v -o /dev/null https://github.com/ 2>&1 | tail -5) > /dev/console; exit 1
  fi
  sleep 15
done
say network-up
pkg install -y git autoconf automake libtool gmake python3 gettext-runtime pkgconf bash ksh93 fio coreutils gsed || say pkg-failed
fetch -q -o /tmp/src.txz https://download.freebsd.org/releases/amd64/$(freebsd-version -k | sed 's/-p[0-9]*//')/src.txz && tar -C / -xf /tmp/src.txz || say src-fetch-failed
git clone -q --depth 1 -b zil-prime-arc https://github.com/markroper/zfs.git /var/tmp/zfs || say clone-failed
cd /var/tmp/zfs
say "head $(git rev-parse --short HEAD) kernel $(uname -r)"
if ./autogen.sh && ./configure --enable-debug MAKE=gmake && gmake -j$(sysctl -n hw.ncpu); then say BUILD-OK; else say BUILD-FAILED; grep -n 'error:' /var/log/zbuild.log | tail -20 > /dev/console; exit 1; fi
grep -n 'warning:' /var/log/zbuild.log | grep -E 'zil\.c|dsl_pool\.c' > /dev/console && say WARNINGS-IN-CHANGED-FILES
./scripts/zfs.sh || { say LOAD-FAILED; exit 1; }
say "loaded; prime sysctl: $(sysctl -n vfs.zfs.zil.replay_prime_arc) prime_delay: $(sysctl -n vfs.zfs.zil_replay_prime_delay_ms)"
for prime in 0 1; do
  sysctl vfs.zfs.zil.replay_prime_arc=$prime >/dev/null
  truncate -s 2g /var/tmp/v0; truncate -s 512m /var/tmp/s0
  ./zpool create -f tp /var/tmp/v0 log /var/tmp/s0 && ./zfs create tp/fs
  mkdir /tp/fs/a /tp/fs/b
  i=0; while [ $i -lt 2000 ]; do : > /tp/fs/a/f$i; dd if=/dev/random of=/tp/fs/a/f$i bs=64k count=2 status=none; i=$((i+1)); done
  sync; ./zpool sync tp
  dd if=/dev/random of=/tp/fs/zp bs=4k count=1 conv=fsync status=none
  ./zpool freeze tp
  i=0; while [ $i -lt 2000 ]; do ln /tp/fs/a/f$i /tp/fs/b/l$i; dd if=/dev/zero of=/tp/fs/a/f$i bs=1k count=1 seek=$((i % 100 + 3)) conv=notrunc status=none; touch -t 202001010000 /tp/fs/a/f$i; i=$((i+1)); done
  dd if=/dev/zero of=/tp/fs/sync bs=4k count=1 conv=fsync status=none
  sha256 -q /tp/fs/a/f* | sha256 -q > /var/tmp/sum.before
  ./zpool export tp
  ./zpool import -d /var/tmp tp || say "prime=$prime IMPORT-FAILED"
  NL=$(ls /tp/fs/b | wc -l | tr -d ' ')
  sha256 -q /tp/fs/a/f* | sha256 -q > /var/tmp/sum.after
  cmp -s /var/tmp/sum.before /var/tmp/sum.after && S=match || S=MISMATCH
  MT=$(stat -f %Sm -t %Y /tp/fs/a/f1999)
  ERR=$(dmesg | grep -c 'replay transaction error')
  say "replay prime=$prime links=$NL data=$S mtime_year=$MT replay_errors=$ERR"
  ./zpool destroy tp; rm -f /var/tmp/v0 /var/tmp/s0
done
mkdir -p /var/tmp/zt-ztest
./ztest -V -T 300 -f /var/tmp/zt-ztest -o zfs_zil_replay_prime_arc=1 > /var/log/ztest.log 2>&1 && say ZTEST-OK || { say ZTEST-FAILED; tail -20 /var/log/ztest.log > /dev/console; }
say DONE
