#!/bin/bash
# usage: build-patch.sh <name> <git-ref> <patch> <debug|release>
set -e
name=$1 ref=$2 patch=$3 mode=$4
cd /var/tmp
git -C zfs.git fetch -q https://github.com/markroper/zfs.git '+refs/heads/zil-prime-arc*:refs/remotes/fork/zil-prime-arc*'
rm -rf /var/tmp/b-$name; git -C zfs.git worktree prune
git -C zfs.git worktree add -f -q --detach /var/tmp/b-$name $ref
cd /var/tmp/b-$name
git apply $patch
opt=""; [ "$mode" = debug ] && opt="--enable-debug"
( ./autogen.sh && ./configure $opt && make -j$(nproc) ) > build.log 2>&1 || { echo BUILD-FAILED; grep -n -B2 -A3 'error:' build.log | head -40; exit 1; }
echo "BUILD-OK $name $mode"
grep -n 'warning:' build.log | grep -E 'zil\.c' | head -20 || true
