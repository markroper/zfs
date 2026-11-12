#!/bin/sh
# FreeBSD verification of a ref.  MODE=prime: prime tests (default and
# priming forced on) and ztest.  MODE=full: the whole ZTS suite.
# Results go to the console and /var/tmp/evidence; the SSM agent allows
# fetching the logs.
REF=__REF__
MODE=__MODE__
exec > /var/log/zbuild.log 2>&1
mkdir -p /var/tmp/evidence
say() { echo "ZTEST: $*"; echo "ZTEST: $*" > /dev/console; echo "ZTEST: $*" >> /var/tmp/evidence/summary.txt; }
say start ref=$REF mode=$MODE
grep -q nameserver /etc/resolv.conf || echo "nameserver 169.254.169.253" > /etc/resolv.conf
export ASSUME_ALWAYS_YES=yes
n=0; until pkg bootstrap -f >/tmp/pkgboot.log 2>&1; do n=$((n+1)); [ $n -gt 20 ] && { say no-network; exit 1; }; sleep 15; done
pkg install -y amazon-ssm-agent && { sysrc amazon_ssm_agent_enable=YES; service amazon-ssm-agent start; } || say ssm-agent-failed
pkg install -y autoconf automake autotools base64 checkbashisms fio gettext gettext-runtime git gmake gsed jq ksh libtool lscpu pkgconf python python3 pamtester rsync xxhash sudo bash coreutils || say pkg-failed
pkg install -xy '^py3[[:digit:]]+-cffi$' '^py3[[:digit:]]+-sysctl$' '^py3[[:digit:]]+-setuptools$' '^py3[[:digit:]]+-packaging$' || true
fetch -q -o /tmp/src.txz https://download.freebsd.org/releases/amd64/$(freebsd-version -k | sed 's/-p[0-9]*//')/src.txz && tar -C / -xf /tmp/src.txz || say src-fetch-failed
pw useradd zts -m -s /bin/sh
echo 'zts ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/zts
git clone -q https://github.com/markroper/zfs.git /var/tmp/zfs || say clone-failed
cd /var/tmp/zfs && git checkout -q $REF || say checkout-failed
say "head $(git rev-parse --short HEAD) kernel $(uname -r)"
if ./autogen.sh && ./configure --enable-debug MAKE=gmake && gmake -j$(sysctl -n hw.ncpu); then say BUILD-OK; else say BUILD-FAILED; exit 1; fi
grep -n 'warning:' /var/log/zbuild.log | grep -E 'zil\.c|dsl_pool\.c' > /var/tmp/evidence/warnings.txt && say WARNINGS-IN-CHANGED-FILES
./scripts/zfs.sh || { say LOAD-FAILED; exit 1; }
chown -R zts /var/tmp/zfs
if [ $MODE = full ]; then
  su -m zts -c "cd /var/tmp/zfs && ./scripts/zfs-tests.sh -v -s 3G" > /var/tmp/evidence/zts-full.log 2>&1
  say "SUMMARY $(grep -E '^(PASS|FAIL|SKIP|KILLED|RERAN)' /var/tmp/evidence/zts-full.log | tr -s ' \t' ' ' | tr '\n' ' ')"
  grep -E '\[(FAIL|KILLED)\]' /var/tmp/evidence/zts-full.log | sed 's|.*/functional/||; s/ (run as.*\[/ [/' > /var/tmp/evidence/failed.txt
  say "FAILED-COUNT $(wc -l < /var/tmp/evidence/failed.txt)"
  sed -n '/^Tests with results other than PASS that are expected/,$p' /var/tmp/evidence/zts-full.log > /var/tmp/evidence/zts-report.txt
else
  run_tests() {
    label=$1
    for t in slog_replay_prime_fs slog_replay_prime_heal slog_replay_prime_volume slog_replay_prime_race slog_replay_fs_001 slog_replay_fs_002 slog_replay_volume; do
      rm -f /var/tmp/file-vdev* /var/tmp/tunable-*; sleep 2
      su -m zts -c "cd /var/tmp/zfs && ./scripts/zfs-tests.sh -t /var/tmp/zfs/tests/zfs-tests/tests/functional/slog/$t.ksh" > /var/tmp/evidence/zts-$label-$t.log 2>&1
      r=$(grep -E "Test:.*/$t.ksh" /var/tmp/evidence/zts-$label-$t.log | grep -oE '\[(PASS|FAIL|SKIP|KILLED)\]' | tail -1)
      say "zts $label $t $r"
    done
  }
  run_tests default
  sysctl vfs.zfs.zil.replay_prime_arc=1 >/dev/null
  run_tests prime-on
  sysctl vfs.zfs.zil.replay_prime_arc=0 >/dev/null
  mkdir -p /var/tmp/zt-ztest
  ./ztest -V -T 300 -f /var/tmp/zt-ztest -o zfs_zil_replay_prime_arc=1 > /var/tmp/evidence/ztest.log 2>&1 && say ZTEST-OK || say ZTEST-FAILED
fi
sed "s/^ZTEST:/ZFINAL:/" /var/tmp/evidence/summary.txt > /dev/console
say DONE
