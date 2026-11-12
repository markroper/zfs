#!/bin/bash
# Linux verification of the final commit; evidence goes to /var/tmp/evidence-linux.
set -u
cd /var/tmp/zt
E=/var/tmp/evidence-linux; rm -rf $E; mkdir -p $E
SC1=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0af627857d03639c4
git -C /var/tmp/zfs.git fetch -q https://github.com/markroper/zfs.git '+refs/heads/zil-prime-arc:refs/remotes/fork/zil-prime-arc'
SHA=$(git -C /var/tmp/zfs.git rev-parse fork/zil-prime-arc); echo "HEAD $SHA" | tee $E/head.txt
for m in debug release; do
  n=final-$m; rm -rf /var/tmp/b-$n; git -C /var/tmp/zfs.git worktree prune
  git -C /var/tmp/zfs.git worktree add -f -q --detach /var/tmp/b-$n $SHA
  opt=""; [ $m = debug ] && opt="--enable-debug"
  (cd /var/tmp/b-$n && ./autogen.sh && ./configure $opt && make -j$(nproc)) > /var/tmp/b-$n/build.log 2>&1 && echo "BUILD-OK $m" || { echo "BUILD-FAILED $m"; exit 1; }
  grep -n 'warning:' /var/tmp/b-$n/build.log | grep -E 'zil\.c|dsl_pool\.c' > $E/warnings-$m.txt; echo "WARNINGS-$m $(wc -l < $E/warnings-$m.txt)"
done
(cd /var/tmp/b-final-debug && make checkstyle > $E/checkstyle.log 2>&1; echo "CHECKSTYLE rc=$?")
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
sed -e 's|^B=.*|B=/var/tmp/b-final-debug|' newtests-rev2.sh > newtests-final.sh; chmod +x newtests-final.sh
./newtests-final.sh > $E/prime-tests.txt 2>&1
for t in volume fs heal race; do grep -hE "Test:.*slog_replay_prime_$t" new-slog_replay_prime_$t.log | sed 's/.*functional\/slog\///'; cp new-slog_replay_prime_$t.log $E/; done | tee -a $E/prime-tests.txt
rm -f /var/tmp/tunable-* /var/tmp/file-vdev*
./zts-prime.sh /var/tmp/b-final-debug slog > $E/slog-prime-on.txt 2>&1; cat $E/slog-prime-on.txt
cp /var/tmp/b-final-debug/zts-prime-slog.log $E/ 2>/dev/null
echo "=== perf"
for wl in write link create remove rename truncate clone; do ./perf2.sh run /var/tmp/b-rel-base 0 base /var/tmp/img-$wl delay:23; done | tee -a $E/perf.txt
for r in 1 2 3; do for wl in write link create remove rename truncate clone; do ./perf2.sh run /var/tmp/b-final-release 1 final /var/tmp/img-$wl delay:23; done; done | tee -a $E/perf.txt
for wl in write link; do ./perf2.sh run /var/tmp/b-rel-base 0 base /var/tmp/img-$wl dev:$SC1; ./perf2.sh run /var/tmp/b-final-release 1 final /var/tmp/img-$wl dev:$SC1; done | sed "s|dev:$SC1|sc1|" | tee -a $E/perf.txt
echo FINAL-DONE
