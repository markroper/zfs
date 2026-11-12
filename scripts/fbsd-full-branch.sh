#!/bin/sh
# FreeBSD: build the zil-prime-arc branch and run the slog ZTS tests in-tree.
exec > /var/log/zbuild.log 2>&1
say() { echo "ZTEST: $*"; echo "ZTEST: $*" > /dev/console; }
say start
grep -q nameserver /etc/resolv.conf || echo "nameserver 169.254.169.253" > /etc/resolv.conf
export ASSUME_ALWAYS_YES=yes
n=0; until pkg bootstrap -f >/tmp/pkgboot.log 2>&1; do n=$((n+1)); [ $n -gt 20 ] && { say no-network; exit 1; }; sleep 15; done
pkg install -y autoconf automake autotools base64 checkbashisms fio gettext gettext-runtime git gmake gsed jq ksh libtool lscpu pkgconf python python3 pamtester rsync xxhash sudo bash coreutils || say pkg-failed
pkg install -xy '^py3[[:digit:]]+-cffi$' '^py3[[:digit:]]+-sysctl$' '^py3[[:digit:]]+-setuptools$' '^py3[[:digit:]]+-packaging$' || true
fetch -q -o /tmp/src.txz https://download.freebsd.org/releases/amd64/$(freebsd-version -k | sed 's/-p[0-9]*//')/src.txz && tar -C / -xf /tmp/src.txz || say src-fetch-failed
pw useradd zts -m -s /bin/sh
echo 'zts ALL=(ALL) NOPASSWD: ALL' > /usr/local/etc/sudoers.d/zts
git clone -q https://github.com/markroper/zfs.git /var/tmp/zfs || say clone-failed
cd /var/tmp/zfs && git checkout -q zil-prime-arc || say checkout-failed
say "head $(git rev-parse --short HEAD) kernel $(uname -r)"
if ./autogen.sh && ./configure --enable-debug MAKE=gmake && gmake -j$(sysctl -n hw.ncpu); then say BUILD-OK; else say BUILD-FAILED; exit 1; fi
./scripts/zfs.sh || { say LOAD-FAILED; exit 1; }
chown -R zts /var/tmp/zfs
su -m zts -c "cd /var/tmp/zfs && ./scripts/zfs-tests.sh -v -s 3G" > /var/tmp/zts-full.log 2>&1
say "SUMMARY $(grep -E '^(PASS|FAIL|SKIP|KILLED|RERAN)' /var/tmp/zts-full.log | tr -s ' \t' ' ' | tr '\n' ' ')"
grep -E '^Test.*\[(FAIL|KILLED)\]' /var/tmp/zts-full.log | sed 's|.*/functional/||; s/ (run as.*\[/ [/' | while read l; do say "BAD $l"; done
sed -n '/^Tests with results other than PASS that are expected/,$p' /var/tmp/zts-full.log | grep -E 'FAIL|KILLED' | head -60 | while read l; do say "REPORT $l"; done
say DONE
