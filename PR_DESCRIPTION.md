# Prime ARC to reduce zil_replay and import times

<!-- Title above. Body below follows .github/PULL_REQUEST_TEMPLATE.md -->

### Motivation and Context

ZIL replay is serial. Most records must read the objects they modify (dnodes,
directory ZAPs, and partially overwritten or truncated blocks) before they can be
applied. So on a pool with high read latency, import time grows with the number of
records times the per-read latency. With a large ZIL that can mean minutes to hours.

This picks up #17044, which was closed with the note that the intention was valid but
the implementation was not. The design here is new, and it addresses each point from
that review:

| Feedback on #17044 | This PR |
|---|---|
| Use partially asynchronous primitives such as `dmu_prefetch()` rather than synchronous ones (@amotin) | Priming only calls `dmu_prefetch_dnode()`, `dmu_prefetch_by_dnode()` and `zap_lookup()`. There are no znodes, range locks or held buffers. Dnode prefetches are issued inline. Only work that must first read a dnode or ZAP runs on a taskq. |
| A global flag breaks when ZILs replay in parallel (@amotin) | No global state. Each `zil_replay()` has its own priming state and its own taskq, and `taskq_wait()` waits only for its own tasks. `slog_replay_prime_race` exercises concurrent replays. |
| Make sure it builds on FreeBSD (@amotin) | The kernel change is entirely in common code (`zil.c`). It builds and passes the tests on FreeBSD 14.5 and 15.1 (details below). |
| How long do the check and claim stages take, and do they already warm the ARC? (@pcd1193182) | They walk only the log chain and don't touch the dnodes, directories or data blocks replay needs. When the log is on the slow device, that serial chain walk dominates import, and priming can't help because each block's pointer to the next is inside the block. With the log on a fast SLOG, replay's own reads dominate, which is the case this targets. |

### Description

When `zfs_zil_replay_prime_arc=1` (the default is 0), `zil_replay()` first parses the
log once and prefetches what the serial replay pass will read. Then it runs replay
unchanged.

| Record | Prefetched | Where |
|---|---|---|
| TX_CREATE, MKDIR, MKXATTR, SYMLINK and `_ATTR`/`_ACL` variants | parent dnode; dnode block holding the new object; directory entry for plain creates | dnodes inline, entry on taskq |
| TX_REMOVE, TX_RMDIR | directory dnode; directory entry and the dnode it names | inline + taskq |
| TX_LINK | directory and linked dnodes; directory entry | inline + taskq |
| TX_RENAME, RENAME_EXCHANGE, RENAME_WHITEOUT | both directory dnodes; both entries; whiteout dnode block | inline + taskq |
| TX_WRITE, TX_WRITE2 | partial first and last data blocks; L1+ over the range | taskq |
| TX_TRUNCATE; TX_SETATTR with `AT_SIZE` | partial block at the new end; L1+ over the freed range | taskq |
| TX_CLONE_RANGE | L1+ over the range | taskq |
| TX_SETATTR (no size change), TX_ACL, ACL_V0, SETSAXATTR | object dnode | inline |

A "directory entry" prefetch is a `zap_lookup()` of the name, which reads the ZAP
blocks replay will search or modify, followed by a prefetch of the named dnode. Names
are taken only from the simple layouts, where the name directly follows the record:
creates without xvattr, ACL or FUID data, plus removes, links and renames. Parsing is
bounded by `lrc_reclen`, and names are skipped for logs of the other byte order. Other
records still get their dnodes primed.

Safety:
- **Read-only and best-effort.** Nothing dirties a buffer or assigns a tx. Replay is
  unchanged and still reads anything priming missed.
- **Objects the log creates are not primed.** They don't exist before replay. A prime
  task could otherwise observe a dnode or microzap that replay is still initializing:
  `dnode_allocate()` sets `dn_type` before the block size, and `mzap_create_impl()`
  fills in the header after the block is visible.
- **No hold during a claim.** If a create would take a dnode slot a prime task held,
  replay waits for the prime tasks before that create. This can only happen if the log
  frees an object number and later reuses it, and it matters because the claim after
  `dnode_try_claim()` must not fail. Replay also waits before retrying a failed record.
- **Bounded.** Each priming replay creates its own taskq (16 threads,
  `TASKQ_DYNAMIC`) and waits for it every 1024 dispatches. It tracks at most 65536
  objects (about 2 MiB); past that, the rest of the log is not primed.
- **No lifetime issues.** Prime tasks never wait on replay or on txg sync, and
  `zil_replay()` drains its tasks before it returns.

New tunables, documented in `zfs.4`:
- `zfs_zil_replay_prime_arc`: 0 or 1.
- Debug only, for tests: `zfs_zil_replay_record_delay_ms`,
  `zfs_zil_replay_prime_delay_ms`.

Known limits, documented in the man page:
- **Whole log first.** The whole log is primed before replay starts, so the benefit
  depends on the prefetched blocks still being in the ARC.
- **Read parallelism.** Prefetches use `ZIO_PRIORITY_SYNC_READ`, so parallelism per
  leaf vdev is bounded by `zfs_vdev_sync_read_max_active`.
- **Silent repairs.** As with any prefetch, checksum errors that a priming prefetch
  finds are repaired without being counted or reported. The dnode and directory reads
  made to issue those prefetches are ordinary reads, and their errors are counted and
  reported as usual.
- **Not primed:** WR_INDIRECT log data blocks and names of 256 bytes or longer.
- **Split writes.** A write logged in several pieces (a large write split across log
  blocks) is primed piece by piece. Blocks at piece boundaries may be read even though
  replay overwrites them whole.

Tests added:
- **`slog_replay_prime_fs`:** replays the same saved log with and without priming, and
  requires identical results that match the pre-export copy. The log contains every
  record type above. zdb confirms each type is present.
- **`slog_replay_prime_heal`:** one mirror side is overwritten with random data. Primed
  replay must still be correct, with no data errors and a clean scrub.
- **`slog_replay_prime_volume`:** a zvol with ext4 (Linux) or UFS (FreeBSD) on top,
  including discards.
- **`slog_replay_prime_race`:** concurrent replays, and draining outstanding prime
  tasks. Linux only, because it reads the debug log.

### How Has This Been Tested?

Results below are for `97a9dde7e`. This PR's commit, `670773fe6`, differs from `97a9dde7e` only in replacing the per-pool taskq with a per-replay taskq, narrowing name parsing, and skipping priming if the taskq can't be created. On `3a022ef09` (`670773fe6` minus that taskq check), the Linux and FreeBSD 14.5 build, checkstyle and commitcheck, prime tests, `slog_replay_*` tests, the full Linux `slog` tag and ztest were rerun with the same results, and one perf run per workload matched the numbers below. Across the two commits there were 39 perf runs, and every one matched its digest with zero replay errors.

**Linux** (Ubuntu 24.04, kernel 7.0, m7i.4xlarge):

| Check | Result |
|---|---|
| Debug and release builds; warnings in changed files | ✅ both; 0 warnings |
| `make checkstyle`; `make commitcheck` | ✅; ✅ |
| New tests `slog_replay_prime_{fs,heal,volume,race}` | ✅ 4/4 |
| Full `slog` tag with `zfs_zil_replay_prime_arc=1` forced on | ✅ 33/33, 0 replay errors |
| ztest 300 s with `-o zfs_zil_replay_prime_arc=1` | ✅ |

**FreeBSD** (debug builds):

| Check | 14.5 | 15.1 |
|---|---|---|
| Build; warnings in changed files | ✅; 0 warnings | ✅; 0 warnings |
| New tests, default and priming forced on | ✅ fs, heal, volume (race: Linux only) | ✅ fs, heal, volume (race: Linux only) |
| `slog_replay_fs_001`, `_002`, `slog_replay_volume`, default and priming forced on | ✅ | ✅ |
| ztest 300 s with priming | ✅ | ✅ |
| Full ZTS suite vs master on the same host | ✅ no new failures: master 1,787 pass / 73 fail / 78 skip / 2 killed; this PR 1,792 / 71 / 79 / 2. Every failure here also fails on master; the ~70 shared ones come from this environment, and none are slog or ZIL tests | — |

**Code review:** three independent read-only reviews of the code, one focused on
durability. They found no way for priming to change on-disk state or the outcome of
replay on ZPL or zvol logs. Issues they did raise are fixed in this commit:
- a dnode or microzap observed while replay was initializing it;
- unbounded memory where a taskq ignores `maxalloc`;
- multi-slot dnode creates;
- a fixed thread count, and `TASKQ_DYNAMIC`;
- byteswapped names;
- duplicate warnings from the priming pass.

**Benchmarks.** Each workload's log is built once on fast storage under
`zpool freeze`. Every variant then replays the identical pool image from a slow
device, with the log on a fast SLOG device. Import time is measured, and every run is
verified by a digest of each path's mode, size, link count and contents, plus a dmesg
check for replay errors. The slow device adds 23 ms to every read using dm-delay over
gp3 (23 ms is EBS sc1's measured QD1 random-read latency). That models storage with
high latency but parallel reads. Release builds; mean of 3 reps for this PR:

| Workload | master | this PR | speedup |
|---|---|---|---|
| TX_WRITE: 8,192 sync 4K rewrites, 6,511 distinct 128K blocks | 254.2 s | 22.7 s | 11.2× |
| TX_LINK: 10,000 links to random files out of 200,000 | 124.7 s | 5.3 s | 23.7× |
| TX_CREATE: 10,000 creates in 1,000 directories | 51.2 s | 4.6 s | 11.1× |
| TX_REMOVE: 10,000 removes | 153.6 s | 6.1 s | 25.2× |
| TX_RENAME: 10,000 cross-directory renames | 153.5 s | 6.4 s | 24.0× |
| truncate (TX_SETATTR size): 2,000 files cut inside a block | 102.8 s | 8.4 s | 12.2× |
| TX_CLONE_RANGE: 2,000 × 4-block clones | 53.5 s | 5.7 s | 9.3× |

- **Device read counts are unchanged.** Priming overlaps reads rather than avoiding them.
- **Disabled, it costs nothing.** With the tunable off, import time matches master.
- **On real EBS sc1** (IOPS- and throughput-limited), the gain is smaller:
  TX_WRITE 805.9 s → 714.9 s (1.13×), TX_LINK 595.4 s → 382.5 s (1.56×). Parallel reads can't beat the device's random-read limit.
- **The earlier design** in #17044 (znode-based) reached 6.3× on TX_WRITE and 6.9× on
  TX_LINK on the same images.

Scripts, logs and full per-run results:
https://github.com/markroper/zfs/tree/zil-prime-arc-notes

### Types of Changes
- [ ] Bug fix (non-breaking change which fixes an issue)
- [x] New feature (non-breaking change which adds functionality)
- [x] Performance enhancement (non-breaking change which improves efficiency)
- [ ] Code cleanup (non-breaking change which makes code smaller or more readable)
- [ ] Quality assurance (non-breaking change which makes the code more robust against bugs)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Library ABI change (libzfs, libzfs\_core, libnvpair and libzfsbootenv)
- [x] Documentation (a change to man pages or other documentation)

### Priority
- [ ] Critical
- [ ] High
- [x] Medium (a later release is fine: a fix for an uncommon setup, a new feature, a performance gain, a test or CI improvement)
- [ ] Low

### Checklist
- [x] My code follows the OpenZFS [code style requirements](https://github.com/openzfs/zfs/blob/master/.github/CONTRIBUTING.md#coding-conventions).
- [x] I have updated the documentation accordingly.
- [x] I have read the [**contributing** document](https://github.com/openzfs/zfs/blob/master/.github/CONTRIBUTING.md).
- [x] I have added [tests](https://github.com/openzfs/zfs/tree/master/tests) to cover my changes.
- [x] I have run the ZFS Test Suite with this change applied.
- [x] All commit messages are properly formatted and contain [`Signed-off-by`](https://github.com/openzfs/zfs/blob/master/.github/CONTRIBUTING.md#signed-off-by).
