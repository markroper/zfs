#!/bin/bash
# usage: build.sh <name> <git-ref> <debug|release>
set -e
name=$1 ref=$2 mode=$3
cd /var/tmp
[ -d zfs.git ] || git clone -q --bare https://github.com/markroper/zfs.git zfs.git
git -C zfs.git fetch -q https://github.com/markroper/zfs.git '+refs/heads/zil-prime-arc-*:refs/remotes/fork/zil-prime-arc-*'
rm -rf /var/tmp/b-$name; git -C zfs.git worktree prune
git -C zfs.git worktree add -f -q --detach /var/tmp/b-$name $ref
cd /var/tmp/b-$name
opt=""; [ "$mode" = debug ] && opt="--enable-debug"
( ./autogen.sh && ./configure $opt && make -j$(nproc) ) > build.log 2>&1 || { echo BUILD-FAILED; grep -n 'error:' build.log | head -20; tail -20 build.log; exit 1; }
echo "BUILD-OK $name $(git rev-parse --short HEAD) $mode"
grep -n 'warning:' build.log | grep -v 'libtool\|automake' | head -20 || true
