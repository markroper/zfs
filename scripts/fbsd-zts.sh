#!/bin/sh
# FreeBSD: build the zil-prime-arc branch and run the slog ZTS tests in-tree.
exec > /var/log/zbuild.log 2>&1
say() { echo "ZTEST: $*"; echo "ZTEST: $*" > /dev/console; echo "ZTEST: $*" >> /var/tmp/zts-summary; }
say start
grep -q nameserver /etc/resolv.conf || echo "nameserver 169.254.169.253" > /etc/resolv.conf
export ASSUME_ALWAYS_YES=yes
n=0; until pkg bootstrap -f >/tmp/pkgboot.log 2>&1; do n=$((n+1)); [ $n -gt 20 ] && { say no-network; exit 1; }; sleep 15; done
pkg install -y autoconf automake autotools base64 checkbashisms fio gettext gettext-runtime git gmake gsed jq ksh libtool lscpu pkgconf python python3 pamtester rsync xxhash sudo bash coreutils || say pkg-failed
pkg install -xy '^py3[[:digit:]]+-cffi$' '^py3[[:digit:]]+-sysctl$' '^py3[[:digit:]]+-setuptools$' '^py3[[:digit:]]+-packaging$' || true
fetch -q -o /tmp/src.txz https://download.freebsd.org/releases/amd64/$(freebsd-version -k | sed 's/-p[0-9]*//')/src.txz && tar -C / -xf /tmp/src.txz || say src-fetch-failed
pw useradd zts -m -s /bin/sh
echo 'zts ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/zts
git clone -q --depth 1 -b zil-prime-arc https://github.com/markroper/zfs.git /var/tmp/zfs || say clone-failed
cd /var/tmp/zfs
say "head $(git rev-parse --short HEAD) kernel $(uname -r)"
if ./autogen.sh && ./configure --enable-debug MAKE=gmake && gmake -j$(sysctl -n hw.ncpu); then say BUILD-OK; else say BUILD-FAILED; grep -n 'error:' /var/log/zbuild.log | tail -20 > /dev/console; exit 1; fi
grep -n 'warning:' /var/log/zbuild.log | grep -E 'zil\.c|dsl_pool\.c' > /dev/console && say WARNINGS-IN-CHANGED-FILES
./scripts/zfs.sh || { say LOAD-FAILED; exit 1; }
say "loaded: replay_prime_arc=$(sysctl -n vfs.zfs.zil.replay_prime_arc) prime_delay_ms=$(sysctl -n vfs.zfs.zil_replay_prime_delay_ms)"
chown -R zts /var/tmp/zfs
run_tests() {
  label=$1
  for t in slog_replay_prime_fs slog_replay_prime_heal slog_replay_prime_volume slog_replay_prime_race slog_replay_fs_001 slog_replay_fs_002 slog_replay_volume; do
    rm -f /var/tmp/file-vdev* /var/tmp/tunable-*; sleep 2
    su -m zts -c "cd /var/tmp/zfs && ./scripts/zfs-tests.sh -t /var/tmp/zfs/tests/zfs-tests/tests/functional/slog/$t.ksh" > /var/tmp/zts-$label-$t.log 2>&1
    r=$(grep -E "Test:.*/$t.ksh" /var/tmp/zts-$label-$t.log | grep -oE '\[(PASS|FAIL|SKIP|KILLED)\]' | tail -1)
    say "zts $label $t $r"
    case "$r" in
    *PASS*|*SKIP*) ;;
    *)
      grep -v '^$' /var/tmp/zts-$label-$t.log | head -8 | sed 's/^/ZTEST:   /' > /dev/console
      o=$(find /var/tmp/test_results -path "*$t.ksh*" -name stdout -newer /var/tmp/zts-$label-$t.log 2>/dev/null; find /var/tmp/test_results -path "*$t.ksh*" -name stdout | tail -1)
      for f in $o; do grep -E '^(ERROR|FAIL)|log_fail|log_unsupported|UNSUPPORTED' $f | head -5 | sed 's/^/ZTEST:   /' > /dev/console; done
      ;;
    esac
  done
}
run_tests default
sysctl vfs.zfs.zil.replay_prime_arc=1 >/dev/null
run_tests prime-on
say "prime sysctl at end: $(sysctl -n vfs.zfs.zil.replay_prime_arc)"
sed "s/^ZTEST:/ZFINAL:/" /var/tmp/zts-summary | grep -v "ZFINAL:   " > /dev/console
say DONE
