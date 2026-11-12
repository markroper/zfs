# ZIL replay ARC priming: code, testing, performance, durability

Covers openzfs/zfs#17044, reworked on `markroper/zfs`.

| Branch | Head | What it is |
|---|---|---|
| `zil-prime-arc` | `670773fe6` | **Candidate.** One commit on master: the dmu_prefetch design for every record type that benefits, plus tests |
| `zil-prime-arc-port` | `448c02f27` | Faithful port of the original znode-based implementation, with BSD and other fixes |
| `zil-prime-arc-prefetch` | `b48189dda` | Earlier prefetch design (TX_WRITE, TX_LINK and TX_SETATTR only), as a second commit on the port. "prefetch v1" below |
| baseline | `47d0a3220` | `openzfs/zfs` master the branches are based on |

## Summary

Import time with the log on a fast SLOG and every pool read taking 23 ms, measured on
`97a9dde7e`. Each variant replays the identical pool image. "prefetch" is the mean of
3 reps:

| Workload (records) | master | **`zil-prime-arc`** |
|---|---|---|
| TX_WRITE: 8,193 partial-block rewrites | 254.2 s | **22.7 s (11.2×)** |
| TX_LINK: 10,000 links | 124.7 s | **5.3 s (23.7×)** |
| TX_CREATE: 10,000 creates in 1,000 directories | 51.2 s | **4.6 s (11.1×)** |
| TX_REMOVE: 10,000 removes | 153.6 s | **6.1 s (25.2×)** |
| TX_RENAME: 10,000 cross-directory renames | 153.5 s | **6.4 s (24.0×)** |
| Truncate (TX_SETATTR size): 2,000 files | 102.8 s | **8.4 s (12.2×)** |
| TX_CLONE_RANGE: 2,000 clones | 53.5 s | **5.7 s (9.3×)** |

- **Correctness:** every run replayed data that matched the digest taken before export,
  with zero replay errors.
- **IOPS-limited EBS sc1:** the gain is smaller there, 1.13× on TX_WRITE and 1.56× on
  TX_LINK.
- **Earlier designs:** the znode-based port reached 6.3× (TX_WRITE) and 6.9× (TX_LINK)
  on the same images.

## Code

Commit [`670773fe6`](https://github.com/markroper/zfs/commit/670773fe6a86ed55b519ac3c76a67382c3208eb7) on
[`zil-prime-arc`](https://github.com/markroper/zfs/tree/zil-prime-arc). It is one commit
on `openzfs/zfs` master `47d0a3220`.
[Full diff vs master](https://github.com/markroper/zfs/compare/master...zil-prime-arc).

```
man/man4/zfs.4                                     |  39 ++
 module/zfs/zil.c                                   | 618 +++++++++++++++++++++
 tests/runfiles/common.run                          |   7 +-
 tests/zfs-tests/include/tunables.cfg               |   3 +
 tests/zfs-tests/tests/Makefile.am                  |   4 +
 tests/zfs-tests/tests/functional/slog/slog.kshlib  |  15 +
 .../tests/functional/slog/slog_replay_prime_fs.ksh | 290 ++++++++++
 .../functional/slog/slog_replay_prime_heal.ksh     | 122 ++++
 .../functional/slog/slog_replay_prime_race.ksh     | 192 +++++++
 .../functional/slog/slog_replay_prime_volume.ksh   | 124 +++++
 10 files changed, 1411 insertions(+), 3 deletions(-)
```

Kernel code is in `zil.c` only. Not touched: `zil_replay()`'s signature, `zfs_replay.c`,
`dsl_pool.c`, the zvol code, every OS-specific file, and ztest.

### What gets primed, by record type

| Record | Prefetched | Where it runs |
|---|---|---|
| TX_CREATE, MKDIR, MKXATTR, SYMLINK, `_ATTR` and `_ACL` variants | parent dnode; dnode block holding the new object (`dmu_object_claim`); directory entry for plain CREATE/MKDIR/SYMLINK without FUID domains | dnodes inline, entry on taskq |
| TX_REMOVE, TX_RMDIR | dir dnode; directory entry and the dnode it names | dnode inline, entry on taskq |
| TX_LINK | dir dnode and linked dnode; directory entry | inline and taskq |
| TX_RENAME, RENAME_EXCHANGE, RENAME_WHITEOUT | source and target dir dnodes; both entries (and any existing target's dnode); whiteout object's dnode block | inline and taskq |
| TX_WRITE, TX_WRITE2 | partial first and last data blocks, L1+ over the range | taskq |
| TX_TRUNCATE; TX_SETATTR with `AT_SIZE` | partial block at the new end, L1+ over the freed range | taskq |
| TX_CLONE_RANGE | L1+ over the range (cloning replaces whole blocks) | taskq |
| TX_SETATTR (no size change), TX_ACL, ACL_V0, SETSAXATTR | object dnode | inline |

"Directory entry" means a `zap_lookup()` of the name. That reads the ZAP header and leaf
blocks that replay will search or modify, and then the dnode the entry names is
prefetched. Names are taken only from the simple layouts, where the name directly follows the
record: creates without xvattr, ACL or FUID data, plus removes, links and renames.
Parsing is bounded by `lrc_reclen`. Other records still get their dnodes primed.

**Tunables:**

| Name | Default | Notes |
|---|---|---|
| `zfs_zil_replay_prime_arc` | 0 | Enables priming |
| `zfs_zil_replay_record_delay_ms` | 0 | Debug builds only, for tests |
| `zfs_zil_replay_prime_delay_ms` | 0 | Debug builds only, for tests |

Fixed, not tunable: each priming replay creates its own `z_zil_prime` taskq of 16 threads
(`TASKQ_DYNAMIC`). It waits for that taskq every 1024 dispatches, and tracks at most 65,536
objects.

On FreeBSD these are `vfs.zfs.zil.replay_prime_arc` and `vfs.zfs.zil_replay_*_delay_ms`.

### Per-replay state

```c
/* Prime the ARC before ZIL replay; see zfs(4). */
static int zfs_zil_replay_prime_arc = 0;

/*
 * Each zil_replay() that primes has its own taskq of this many threads.
 * Prime tasks mostly wait for reads, so this doesn't depend on the number
 * of CPUs.
 */
#define	ZIL_REPLAY_PRIME_THREADS	16

/*
 * The most prime tasks dispatched between waits for the taskq to drain,
 * which bounds their memory; not every taskq implementation limits it.
 */
#define	ZIL_REPLAY_PRIME_TASKS_MAX	1024

/*
 * The most objects one zil_replay() tracks, about 2M of memory; past this,
 * priming stops.
 */
#define	ZIL_REPLAY_PRIME_OBJS_MAX	(1ULL << 16)

typedef struct zil_replay_prime_obj {
	avl_node_t	zpo_node;
	uint64_t	zpo_obj;
} zil_replay_prime_obj_t;

/*
 * Priming state of one zil_replay() invocation, used only by the replay
 * thread.  zrps_tq runs this invocation's prime tasks, so taskq_wait()
 * waits for exactly those.  The object sets:
 *
 * - zrps_created: objects that records seen so far create.  They don't
 *   exist before replay, so there's nothing to prime, and a prime task
 *   could otherwise see a dnode or ZAP that replay is still initializing.
 * - zrps_primed: objects prime tasks hold.  Before replaying a record that
 *   creates one of these (its number was freed and reused within the
 *   log), replay waits for the prime tasks, for the same reason.
 */
typedef struct zil_replay_prime_state {
	taskq_t		*zrps_tq;
	uint64_t	zrps_queued;	/* dispatched since the last wait */
	avl_tree_t	zrps_created;
	avl_tree_t	zrps_primed;
	boolean_t	zrps_full;	/* too many objects; stop priming */
	boolean_t	zrps_byteswap;	/* log is of the other byte order */
} zil_replay_prime_state_t;

/* Argument to zil_replay_prime_task(). */
typedef struct zil_replay_prime_arg {
	objset_t	*zrp_os;
	size_t		zrp_size;	/* allocated size of this struct */
	uint64_t	zrp_obj;	/* file, or directory if zrp_name[0] */
	uint64_t	zrp_offset;	/* range to prefetch, if no name */
	uint64_t	zrp_length;
	boolean_t	zrp_data;	/* also prefetch partial data blocks */
	char		zrp_name[];	/* directory entry name, or "" */
} zil_replay_prime_arg_t;
```

### Hook in `zil_replay_log_record()`

Runs after the sequence and claim-txg filters:

```c
	/*
	 * Priming tolerates missing objects, so it skips the check below,
	 * which may block reading the dnode.
	 */
	if (zr->zr_prime_state != NULL) {
		zil_replay_prime_record(zilog, zr->zr_prime_state, lr, txtype);
		return (0);
	}

```

Before replaying a create of an object a prime task held, replay waits for the tasks:

```c
	/*
	 * Don't create an object while a prime task may hold a dnode in any
	 * of the slots it takes; see zil_replay_prime_state_t.
	 */
	uint64_t created, slots;
	if (zr->zr_prime_wait != NULL &&
	    zil_replay_prime_creates(lr, txtype, &created, &slots)) {
		for (uint64_t i = 0; i < slots; i++) {
			if (zil_replay_prime_obj_has(
			    &zr->zr_prime_wait->zrps_primed, created + i)) {
				zil_replay_prime_wait(zr->zr_prime_wait);
				break;
			}
```

Replay's existing retry on error now waits for prime tasks first:

```c
		/*
		 * A prime task's dnode hold can also make creating an
		 * object fail with EEXIST, so wait for them first.
		 */
		if (zr->zr_prime_wait != NULL)
			zil_replay_prime_wait(zr->zr_prime_wait);
		txg_wait_synced(spa_get_dsl(zilog->zl_spa), 0);
```

### Prime task and dispatch

```c
/*
 * Wait for all of one zil_replay() invocation's prime tasks.
 */
static void
zil_replay_prime_wait(zil_replay_prime_state_t *zrps)
{
	if (zrps->zrps_queued != 0)
		zfs_dbgmsg("Waiting for ZIL replay prime tasks");
	taskq_wait(zrps->zrps_tq);
	zrps->zrps_queued = 0;
}

/*
 * Prefetch what replaying a record will read, in one of two ways:
 *
 * - A directory entry (zrp_name[0] != 0): look up the name, which reads
 *   the ZAP blocks that replay will search or modify, and prefetch the
 *   dnode it names, if any.
 * - A range of a file: replay overwrites (TX_WRITE), frees (TX_TRUNCATE)
 *   or clones over (TX_CLONE_RANGE) whole blocks without reading them,
 *   so only a partially covered first or last block needs its data
 *   (zrp_data), but every block in the range needs its indirect blocks.
 *
 * Both may block on reads, which is why this runs on a taskq.
 */
static void
zil_replay_prime_task(void *arg)
{
	zil_replay_prime_arg_t *zrp = arg;
	objset_t *os = zrp->zrp_os;
	uint64_t off = zrp->zrp_offset;
	uint64_t len = zrp->zrp_length;
	dnode_t *dn;

#ifdef ZFS_DEBUG
	if (zfs_zil_replay_prime_delay_ms != 0)
		delay(MSEC_TO_TICK(zfs_zil_replay_prime_delay_ms));
#endif
	if (zrp->zrp_name[0] != '\0') {
		uint64_t de;

		if (zap_lookup(os, zrp->zrp_obj, zrp->zrp_name, 8, 1,
		    &de) == 0) {
			dmu_prefetch_dnode(os, ZFS_DIRENT_OBJ(de),
			    ZIO_PRIORITY_SYNC_READ);
		}
	} else if (len != 0 &&
	    dnode_hold(os, zrp->zrp_obj, FTAG, &dn) == 0) {
		rw_enter(&dn->dn_struct_rwlock, RW_READER);
		uint64_t bs = dn->dn_datablksz;
		uint8_t nlevels = dn->dn_nlevels;
		rw_exit(&dn->dn_struct_rwlock);

		/*
		 * A dnode being allocated has no block size yet.  Objects
		 * replay creates are not primed, so this shouldn't happen.
		 */
		if (bs == 0)
			goto out;

		uint64_t end = off + len;
		boolean_t head = zrp->zrp_data &&
		    (off % bs != 0 || len < bs);
		boolean_t tail = zrp->zrp_data && end % bs != 0 &&
		    (!head || (end - 1) / bs != off / bs);

		if (head) {
			dmu_prefetch_by_dnode(dn, 0, off, 1,
			    ZIO_PRIORITY_SYNC_READ);
		}
		if (tail) {
			dmu_prefetch_by_dnode(dn, 0, end - 1, 1,
			    ZIO_PRIORITY_SYNC_READ);
		}
		if (nlevels > 1) {
			dmu_prefetch_by_dnode(dn, 1, off, len,
			    ZIO_PRIORITY_SYNC_READ);
		}
out:
		dnode_rele(dn, FTAG);
	}
	kmem_free(zrp, zrp->zrp_size);
}

static void
zil_replay_prime_dispatch(zilog_t *zilog, zil_replay_prime_state_t *zrps,
    uint64_t obj, const char *name, size_t namelen, uint64_t off,
    uint64_t len, boolean_t data)
{
	if (zrps->zrps_full || (namelen == 0 && len == 0) ||
	    zil_replay_prime_obj_has(&zrps->zrps_created, obj))
		return;
	zil_replay_prime_obj_add(zrps, &zrps->zrps_primed, obj);
	if (zrps->zrps_full)
		return;

	size_t size = sizeof (zil_replay_prime_arg_t) + namelen + 1;
	zil_replay_prime_arg_t *zrp = kmem_alloc(size, KM_SLEEP);

	zrp->zrp_os = zilog->zl_os;
	zrp->zrp_size = size;
	zrp->zrp_obj = obj;
	zrp->zrp_offset = off;
	/* A length past the largest offset, such as "to EOF", is clamped. */
	zrp->zrp_length = MIN(len, UINT64_MAX - off);
	zrp->zrp_data = data;
	if (namelen != 0)
		memcpy(zrp->zrp_name, name, namelen);
	zrp->zrp_name[namelen] = '\0';

	if (zrps->zrps_queued >= ZIL_REPLAY_PRIME_TASKS_MAX)
		zil_replay_prime_wait(zrps);
	if (taskq_dispatch(zrps->zrps_tq, zil_replay_prime_task, zrp,
	    TQ_SLEEP) == TASKQID_INVALID)
		kmem_free(zrp, size);
	else
		zrps->zrps_queued++;
}
```

### Record dispatch

The name-parsing helpers (`zil_replay_prime_str`, `_skip`, `_advance`, `_create_name`,
`_dirent`) are in the diff.

```c
/*
 * If replaying this record creates an object, return B_TRUE, its number
 * and the number of dnode slots it takes.
 */
static boolean_t
zil_replay_prime_creates(const lr_t *lr, uint64_t txtype, uint64_t *objp,
    uint64_t *slotsp)
{
	uint64_t foid;

	switch (txtype) {
	case TX_CREATE:
	case TX_MKDIR:
	case TX_MKXATTR:
	case TX_SYMLINK:
	case TX_CREATE_ATTR:
	case TX_MKDIR_ATTR:
	case TX_CREATE_ACL:
	case TX_CREATE_ACL_ATTR:
	case TX_MKDIR_ACL:
	case TX_MKDIR_ACL_ATTR:
		if (lr->lrc_reclen < sizeof (lr_create_t))
			return (B_FALSE);
		foid = ((const _lr_create_t *)lr)->lr_foid;
		break;
	case TX_RENAME_WHITEOUT:
		if (lr->lrc_reclen < sizeof (lr_rename_whiteout_t))
			return (B_FALSE);
		foid = ((const lr_rename_whiteout_t *)lr)->lr_wfoid;
		break;
	default:
		return (B_FALSE);
	}
	*objp = LR_FOID_GET_OBJ(foid);
	*slotsp = LR_FOID_GET_SLOTS(foid);
	return (B_TRUE);
}

/*
 * Find the name in a create record.  Only the simple layout is handled,
 * matching zfs_replay_create(): the name follows the record, with no
 * xvattr, ACL or FUID data before it.  Return NULL for anything else,
 * which is then not primed.
 */
static const char *
zil_replay_prime_create_name(const lr_t *lr, uint64_t txtype)
{
	const lr_create_t *lrc = (const lr_create_t *)lr;

	if (lr->lrc_reclen < sizeof (lr_create_t))
		return (NULL);
	switch (txtype) {
	case TX_CREATE:
	case TX_MKDIR:
		/* FUID domains of the owner and group precede the name. */
		if (FUID_INDEX(lrc->lr_create.lr_uid) != 0 ||
		    FUID_INDEX(lrc->lr_create.lr_gid) != 0)
			return (NULL);
		zfs_fallthrough;
	case TX_SYMLINK:
		return ((const char *)&lrc->lr_data[0]);
	default:
		return (NULL);
	}
}

/*
 * Start reading what replaying this record will need.  Dnode prefetches
 * don't block, so issue them here; anything that must first read a dnode
 * or a directory goes to a taskq.  The layouts of the records must match
 * the ZPL replay functions in zfs_replay.c.  A record that doesn't parse
 * is just not primed; replay validates it.
 */
static void
zil_replay_prime_record(zilog_t *zilog, zil_replay_prime_state_t *zrps,
    const lr_t *lr, uint64_t txtype)
{
	objset_t *os = zilog->zl_os;
	const char *end = (const char *)lr + lr->lrc_reclen;
	const char *p;
	uint64_t created, slots;

	if (zrps->zrps_full)
		return;
	if (zil_replay_prime_creates(lr, txtype, &created, &slots)) {
		for (uint64_t i = 0; i < slots; i++) {
			zil_replay_prime_obj_add(zrps, &zrps->zrps_created,
			    created + i);
		}
	}

	switch (txtype) {
	case TX_CREATE:
	case TX_MKDIR:
	case TX_MKXATTR:
	case TX_SYMLINK:
	case TX_CREATE_ATTR:
	case TX_MKDIR_ATTR:
	case TX_CREATE_ACL:
	case TX_CREATE_ACL_ATTR:
	case TX_MKDIR_ACL:
	case TX_MKDIR_ACL_ATTR: {
		const _lr_create_t *lrc = (const _lr_create_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_create_t))
			break;
		dmu_prefetch_dnode(os, lrc->lr_doid, ZIO_PRIORITY_SYNC_READ);
		/* The dnode block that replay will claim the new object in. */
		dmu_prefetch_dnode(os, LR_FOID_GET_OBJ(lrc->lr_foid),
		    ZIO_PRIORITY_SYNC_READ);
		if (txtype != TX_MKXATTR) {
			p = zil_replay_prime_create_name(lr, txtype);
			zil_replay_prime_dirent(zilog, zrps, lrc->lr_doid, &p,
			    end);
		}
		break;
	}
	case TX_REMOVE:
	case TX_RMDIR: {
		const lr_remove_t *lrr = (const lr_remove_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_remove_t))
			break;
		dmu_prefetch_dnode(os, lrr->lr_doid, ZIO_PRIORITY_SYNC_READ);
		p = (const char *)&lrr->lr_data[0];
		zil_replay_prime_dirent(zilog, zrps, lrr->lr_doid, &p, end);
		break;
	}
	case TX_LINK: {
		const lr_link_t *lrl = (const lr_link_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_link_t))
			break;
		dmu_prefetch_dnode(os, lrl->lr_doid, ZIO_PRIORITY_SYNC_READ);
		dmu_prefetch_dnode(os, lrl->lr_link_obj,
		    ZIO_PRIORITY_SYNC_READ);
		p = (const char *)&lrl->lr_data[0];
		zil_replay_prime_dirent(zilog, zrps, lrl->lr_doid, &p, end);
		break;
	}
	case TX_RENAME:
	case TX_RENAME_EXCHANGE:
	case TX_RENAME_WHITEOUT: {
		const _lr_rename_t *lrr = (const _lr_rename_t *)lr;

		if (txtype == TX_RENAME_WHITEOUT) {
			const lr_rename_whiteout_t *lrw =
			    (const lr_rename_whiteout_t *)lr;

			if (lr->lrc_reclen < sizeof (lr_rename_whiteout_t))
				break;
			dmu_prefetch_dnode(os, LR_FOID_GET_OBJ(lrw->lr_wfoid),
			    ZIO_PRIORITY_SYNC_READ);
			p = (const char *)&lrw->lr_data[0];
		} else {
			const lr_rename_t *lrn = (const lr_rename_t *)lr;

			if (lr->lrc_reclen < sizeof (lr_rename_t))
				break;
			p = (const char *)&lrn->lr_data[0];
		}
		dmu_prefetch_dnode(os, lrr->lr_sdoid, ZIO_PRIORITY_SYNC_READ);
		dmu_prefetch_dnode(os, lrr->lr_tdoid, ZIO_PRIORITY_SYNC_READ);
		/* The source name, then the target name. */
		zil_replay_prime_dirent(zilog, zrps, lrr->lr_sdoid, &p, end);
		zil_replay_prime_dirent(zilog, zrps, lrr->lr_tdoid, &p, end);
		break;
	}
	case TX_WRITE:
	case TX_WRITE2: {
		const lr_write_t *lrw = (const lr_write_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_write_t))
			break;
		zil_replay_prime_dispatch(zilog, zrps, lrw->lr_foid, NULL, 0,
		    lrw->lr_offset, lrw->lr_length, B_TRUE);
		break;
	}
	case TX_TRUNCATE: {
		const lr_truncate_t *lrt = (const lr_truncate_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_truncate_t))
			break;
		/* A length of zero frees to the end of the file. */
		zil_replay_prime_dispatch(zilog, zrps, lrt->lr_foid, NULL, 0,
		    lrt->lr_offset, lrt->lr_length == 0 ? UINT64_MAX :
		    lrt->lr_length, B_TRUE);
		break;
	}
	case TX_CLONE_RANGE: {
		const lr_clone_range_t *lrc = (const lr_clone_range_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_clone_range_t))
			break;
		/* Cloning replaces whole blocks, so read only indirects. */
		zil_replay_prime_dispatch(zilog, zrps, lrc->lr_foid, NULL, 0,
		    lrc->lr_offset, lrc->lr_length, B_FALSE);
		break;
	}
	case TX_SETATTR: {
		const lr_setattr_t *lrs = (const lr_setattr_t *)lr;

		if (lr->lrc_reclen < sizeof (lr_setattr_t))
			break;
		/*
		 * A size change frees from the new size to the end of the
		 * file, like TX_TRUNCATE.  lr_mask uses this platform's
		 * AT_* bits, as replay does.
		 */
		if (lrs->lr_mask & AT_SIZE) {
			zil_replay_prime_dispatch(zilog, zrps, lrs->lr_foid,
			    NULL, 0, lrs->lr_size, UINT64_MAX, B_TRUE);
		} else {
			dmu_prefetch_dnode(os, lrs->lr_foid,
			    ZIO_PRIORITY_SYNC_READ);
		}
		break;
	}
	case TX_ACL_V0:
	case TX_ACL:
	case TX_SETSAXATTR:
		/* These all start with lr_ooo_t. */
		if (lr->lrc_reclen < sizeof (lr_ooo_t))
			break;
		dmu_prefetch_dnode(os, ((const lr_ooo_t *)lr)->lr_foid,
		    ZIO_PRIORITY_SYNC_READ);
		break;
	default:
		break;
	}
}
```

### Priming pass and drain in `zil_replay()`

```c
	if (zfs_zil_replay_prime_arc) {
		primed = B_TRUE;
		zrps.zrps_tq = taskq_create("z_zil_prime",
		    ZIL_REPLAY_PRIME_THREADS, minclsyspri, 1, INT_MAX,
		    TASKQ_DYNAMIC);
		zrps.zrps_queued = 0;
		zrps.zrps_full = B_FALSE;
		zrps.zrps_byteswap = zr.zr_byteswap;
		avl_create(&zrps.zrps_created, zil_replay_prime_obj_compare,
		    sizeof (zil_replay_prime_obj_t),
		    offsetof(zil_replay_prime_obj_t, zpo_node));
		avl_create(&zrps.zrps_primed, zil_replay_prime_obj_compare,
		    sizeof (zil_replay_prime_obj_t),
		    offsetof(zil_replay_prime_obj_t, zpo_node));
		zr.zr_prime_state = &zrps;
		zr.zr_prime_wait = &zrps;
		zfs_dbgmsg("Starting zfs_zil_replay_prime_arc");
		(void) zil_parse(zilog, zil_replay_scan_blk,
		    zil_replay_log_record, &zr, zh->zh_claim_txg, B_TRUE);
		zr.zr_prime_state = NULL;
		zfs_dbgmsg("Finished zfs_zil_replay_prime_arc");
	}

	(void) zil_parse(zilog, zil_incr_blks, zil_replay_log_record, &zr,
	    zh->zh_claim_txg, B_TRUE);
	/* If the log ended inside a split write, count it as dropped. */
	zil_replay_split_drop(zilog, &zr, 0);
	/*
	 * Let prime tasks overlap real replay, then drain only this
	 * invocation's tasks before zrps goes out of scope.
	 */
	if (primed) {
		zil_replay_prime_wait(&zrps);
		zr.zr_prime_wait = NULL;
		taskq_destroy(zrps.zrps_tq);
		zil_replay_prime_obj_destroy(&zrps.zrps_created);
		zil_replay_prime_obj_destroy(&zrps.zrps_primed);
	}
```

## Testing status

Candidate commit `670773fe6` (same code as `ee0717ac5`, reworded message), which is `3a022ef09` plus a check that skips priming if `taskq_create()` fails. The 4 prime tests were rerun on it. The Results table below was run on `97a9dde7e`, the same design before the per-replay-taskq and name-parsing simplification. The section "Simplification (in `3a022ef09`)" lists what was rerun on the final commit. Evidence is in [`evidence/`](evidence/).

### New ZTS tests in the commit

- **`slog_replay_prime_fs`** replays the same saved log twice, once with priming and
  once without (vdevs restored in between). It requires both results to be identical to
  each other and to the pre-export copy. The log has every record type priming acts on:
  - **TX_WRITE:** partial head and tail, whole-block, past EOF, a single-block file,
    WR_INDIRECT, and a write to an object removed before replay.
  - **Namespace records, spread over 8 directories:** TX_CREATE, TX_MKDIR, TX_SYMLINK,
    TX_REMOVE, TX_RMDIR, TX_LINK, and TX_RENAME, including a rename over an existing
    name.
  - **xattrs:** TX_MKXATTR (`xattr=dir`) and TX_SETSAXATTR (`xattr=sa`).
  - **Size and clone changes:** TX_TRUNCATE (hole punch), TX_SETATTR size changes within
    a block and to zero, and TX_CLONE_RANGE, both a whole file and a range of an
    existing file.
  - **Attributes:** TX_SETATTR, including on a removed object.
  - **Linux only:** TX_RENAME_EXCHANGE and TX_RENAME_WHITEOUT.
  - **FreeBSD only:** TX_ACL (NFSv4 `setfacl`).

  zdb confirms that each record type is actually in the log.
- **`slog_replay_prime_heal`** is a mirror pool whose data area on one side is
  overwritten with random data before import. Primed replay must still match the copy,
  checksum errors must show up on the damaged side, there must be no data errors, and
  a scrub afterwards must be clean.
- **`slog_replay_prime_volume`** is a zvol with ext4 (Linux, mounted `-o discard`, so it
  also replays zvol TX_TRUNCATE) or UFS (FreeBSD) on top. Partial synchronous overwrites
  are replayed with priming, and the checksums must match.
- **`slog_replay_prime_race`** checks that concurrent dataset replays keep separate
  priming state, and that replay waits for its prime tasks before returning. Linux only.

Each new test also checks the debug log to confirm priming ran.

### Results (on `97a9dde7e`)

| Check | Linux 7.0 (Ubuntu 24.04) | FreeBSD 14.5 | FreeBSD 15.1 |
|---|---|---|---|
| Debug and release build, warnings in changed files | ✅ 0 | ✅ debug, 0 | ✅ debug, 0 |
| `make checkstyle`, `make commitcheck` | ✅ | — | — |
| `slog_replay_prime_fs` (all record types) | ✅ | ✅ default and forced on | ✅ default and forced on |
| `slog_replay_prime_heal` | ✅ | ✅ | ✅ |
| `slog_replay_prime_volume` | ✅ | ✅ | ✅ |
| `slog_replay_prime_race` | ✅ | skipped (Linux only) | skipped (Linux only) |
| `slog_replay_fs_001`, `_002`, `slog_replay_volume`, default and forced on | ✅ (in the `slog` tag) | ✅ | ✅ |
| Full `slog` tag (33 tests), priming forced on | ✅ 33/33, 0 replay errors | — | — |
| ztest 300 s with `-o zfs_zil_replay_prime_arc=1` | ✅ | ✅ | ✅ |
| Full ZTS suite, compared with master on the same host | — | ✅ no new failures (below) | — |
| Image-replay perf, data digest checked after each run | ✅ 32 runs, 0 mismatches, 0 replay errors | — | — |
| Fork CI | not run: fork Actions report "repository invocation blocked" | — | — |

**FreeBSD 14.5 full suite.** Both runs used the same instance type and the same build
options, with priming at its default (off). The complete failure lists are in
`evidence/`:

| | master `47d0a3220` | `97a9dde7e` |
|---|---|---|
| PASS / FAIL / SKIP / KILLED | 1,787 / 73 / 78 / 2 | 1,792 / 71 / 79 / 2 |
| Failures not present in the other run | `zinject/zinject_args`, `send_xdr_encoding/xdr_resume_bookmark_raw_with_write` | none |
| slog or ZIL tests failing | none | none |

- **No new failures.** Every failure on `97a9dde7e` also fails on master.
- **The extra passes:** the three new prime tests, plus the two tests that failed only
  on master. Both look flaky, and neither touches the ZIL.
- **The extra skip** is the Linux-only race test.
- **The ~70 shared failures** (rsend, pyzfs, and the feature and casenorm tests) come
  from this environment.

### Simplification (in `3a022ef09`)

A design review looked for reuse and safety by construction. Two of its suggestions were
adopted:
- **Per-replay taskq.** Each priming `zil_replay()` creates its own `z_zil_prime` taskq
  (16 threads, `TASKQ_DYNAMIC`) and drains it with `taskq_wait()`.
  - This replaced the per-pool `dp_zil_prime_taskq`, the custom counter, mutex and
    condition variable, and the 30 s wait-logging loop.
  - It also removed all `dsl_pool.c`/`.h` changes and the `zfs_zil_prime_taskq_nthr` and
    `zfs_zil_replay_prime_tasks_max` tunables.
  - Memory is bounded by waiting every 1024 dispatches.
- **Only simple name layouts.** Names are primed only where they directly follow the
  record. The duplicated `_ATTR`/`_ACL`/FUID-domain parsing is gone; those records still
  get their dnodes primed.

Not adopted: draining all priming before replay starts. That would have removed the object
sets and the waits before creates, but at the cost of losing the overlap between priming
and replay. No correctness bug requires it.

Kernel and doc lines vs master went from +780 in 4 files to +657 in 2 files, with the
kernel change now only in `zil.c`. The whole commit went from +1534 to +1411.

Rerun on `3a022ef09`:

| Check | Linux 7.0 | FreeBSD 14.5 |
|---|---|---|
| Debug and release build; warnings in changed files | ✅ 0 | ✅ 0 |
| `make checkstyle`, `make commitcheck` | ✅ | — |
| 4 prime tests | ✅ | ✅ default and forced on (race: Linux only) |
| `slog_replay_fs_001`, `_002`, `slog_replay_volume`, priming forced on | ✅ | ✅ |
| Full `slog` tag, priming forced on | ✅ 33/33 | — |
| ztest 300 s with priming | ✅ | ✅ |
| Perf, 1 run per workload at 23 ms, digest checked | ✅ all match, 0 replay errors | — |

Perf for `3a022ef09` is unchanged from `97a9dde7e`:

| Workload | `97a9dde7e` (mean of 3) | `3a022ef09` (1 run) |
|---|---|---|
| write | 22.7 s | 22.4 s |
| link | 5.3 s | 5.5 s |
| create | 4.6 s | 5.0 s |
| remove | 6.1 s | 6.1 s |
| rename | 6.4 s | 6.4 s |
| truncate | 8.4 s | 8.8 s |
| clone | 5.7 s | 5.9 s |

### Independent review fixes (in `387d629cd`)

A cold code review, with no access to the design notes, found these issues in the
previous commit. All are fixed:

| # | Issue | Fix |
|---|---|---|
| 1 | **Divide-by-zero panic.** A prime task could hold an object while replay was creating it. `dnode_allocate()` sets `dn_type` before the block size with no lock held, so the task could see `dn_datablksz == 0` and compute `off % bs`. | Objects that the log creates are not primed: they don't exist before replay. If a primed object's number is freed and re-created within the log, replay waits for the prime tasks before replaying the create. The task also skips `bs == 0` as a backstop. |
| 2 | **ZAP header race.** A directory lookup could race with replay creating that directory's microzap (`mzap_create_impl()` fills in the header after the block is visible). It could cache a `zap_t` with the wrong salt and normalization flags. | Same fix: directories the log creates are not looked up. |
| 3 | **Unbounded memory on FreeBSD.** FreeBSD's taskq ignores maxalloc, so memory grew with the size of the log. | At most `zfs_zil_replay_prime_tasks_max` (1024) tasks queued or running per replay, waited on with the existing condition variable. The object sets are capped (now 65,536 entries); past that, priming stops. |
| 4 | **Too few threads on small hosts.** One thread on a 1–3 CPU host, so priming could slow import. | A fixed `zfs_zil_prime_taskq_nthr` (16), since the work is I/O-bound. |
| 5 | **Idle threads in every pool.** | `TASKQ_DYNAMIC`; Linux starts threads only as needed. FreeBSD ignores the flag. |
| 6 | **Wrong man page.** The text for minalloc/maxalloc was wrong, and the tunables were marked read-write but read only at import. | Removed both tunables and documented `zfs_zil_prime_taskq_nthr` as read at pool import. |
| 7 | **Misleading skip message** in the race test on FreeBSD. | Now says the test reads the Linux debug message log. |

After the fixes, the debug and release builds compile with no warnings in `zil.c`, and
all 4 prime tests pass on Linux. A minimal perf retest, one run per workload at 23 ms,
matched or beat the previous numbers, with matching digests and zero replay errors in
every run:

| Workload | before fixes | after fixes |
|---|---|---|
| write | 23.0 s | 22.5 s |
| link | 5.6 s | 5.6 s |
| create | 6.3 s | 4.6 s |
| remove | 7.4 s | 6.2 s |
| rename | 8.5 s | 6.4 s |
| truncate | 8.6 s | 8.8 s |
| clone | 6.1 s | 5.9 s |

The gains on create, remove and rename are most likely from 16 threads instead of 8.

Not changed: the review's item on large truncates. Truncate-to-EOF and setattr size
changes can each prefetch up to `dmu_prefetch_max` of indirect blocks. The minor items
(TX_WRITE2 data prefetch, cross-endian names, long names, the WR_INDIRECT log-data
block) are also left as is. The full Linux `slog` tag, FreeBSD and checkstyle were not
rerun on `387d629cd`.

### Second review fixes (in `282ab3784`)

A second cold review of `387d629cd` found no correctness bug. These fixes harden it:

| # | Issue | Fix |
|---|---|---|
| R3 | **The wait before a create checked only the object number.** A dnode larger than 512 bytes also takes the following slots. A prime hold on one of those slots made replay's claim fail with ENOSPC, which was safe only because ZPL replay calls `dnode_try_claim()` first. | All slots of a created dnode are added to the "created" set, and replay waits if a prime task held any of them. |
| R1 | **The object-set cap was 2^20 entries,** about 32 MiB per replay, and datasets replay in parallel. | Lowered to 65,536 entries (about 2 MiB). No new tunable; documented in the man page. |
| R2 | **The whole log is primed before replay starts,** so the gain depends on the ARC holding the prefetched blocks. | Documented in the man page. |
| N2 | **Byteswapped logs looked up garbage names.** Blocks of the other byte order are swapped as 64-bit words. | Names aren't primed for those logs. |
| N6 | **Zero-length ranges** dispatched a task that did nothing. | Skipped. |
| N7 | **The man page** said clones prefetch data blocks. | Says indirect blocks. |

Retest on Linux:
- **Build:** debug and release compile cleanly, and `make checkstyle` passes.
- **Tests:** all 4 prime tests pass.
- **Perf:** one run per workload at 23 ms, all matching their digests with zero replay errors:

| Workload | write | link | create | remove | rename | truncate | clone |
|---|---|---|---|---|---|---|---|
| Import time | 22.5 s | 5.1 s | 4.7 s | 6.1 s | 6.5 s | 8.7 s | 5.8 s |

Still open from the second review:
- **Not yet supported:** WR_INDIRECT log-data prefetch, priming of long names, and ztest coverage of priming.
- **Not covered by tests:** the object-reuse paths. The tests freeze the pool, so object numbers are never reused.
- **Minor:** taskq thread-count bounds and the duplicate warning for bad records.
- **Speculative:** an implicit allocation during replay could land on a different object number than it would without priming.

### FreeBSD full-suite comparison

Both runs are on FreeBSD 14.5 on m7i.4xlarge, debug build, with file vdevs on gp3; each
took about 6.5 hours.
- **New tests:** the newer commit adds 4 tests, which account for +2 PASS and +1 SKIP
  (the Linux-only race test).
- **The extra FAIL:** it is `slog_replay_prime_fs` hitting a zdb check for TX_TRUNCATE,
  which FreeBSD's `truncate -s` doesn't log. That check was fixed in `6b2efc1`, and the
  test passes on FreeBSD for `f4472d4`.
- **Common failures:** the roughly 73 failures common to both runs (rsend, pyzfs,
  feature and casenorm tests, among others) come from this environment.
- **Differences:** the harness recorded the first 60 failure entries of each run, and 58
  are identical. The other two differ in opposite directions and don't involve the ZIL:
  `zinject/zinject_args` failed only on master, and
  `raidz/raidz_expand_scrub_repair` failed only on the new commit.

### FreeBSD debug console noise (not caused by this change)

FreeBSD debug kernels print `got error -2 on name … on op 3` plus a backtrace whenever
a lookup fails during rename replay (`zfs_vnops_os.c`, `#ifdef ZFS_DEBUG`). Rename
replay looks up a target name that doesn't exist yet, so tests with many renames flood
the console. It happens with priming off too.

## Performance

### All record types: image replay at 23 ms read latency

The method is the same as the next section: the log is built once on fast storage, each
variant replays the identical image from dm-delay at 23 ms, and the SLOG is on fast
storage. Each run is verified by a digest of every path's mode, size, link count and
contents ([`scripts/perf2-wl.py`](scripts/perf2-wl.py)). Variants:
- **base:** master.
- **prefetch v1:** the earlier commit that primes only TX_WRITE, TX_LINK and TX_SETATTR.
- **all:** `zil-prime-arc`.

**Workloads**, run after `zpool freeze` on images laid out beforehand:
- **create:** 1,000 directories of 200 files each. 10,000 new files in random
  directories, then fsync each directory. Replay must search each directory's ZAP and
  claim each new object's dnode block.
- **remove:** the same layout; 10,000 random files are unlinked. Replay must look up
  each name and read the file's dnode.
- **rename:** the same layout; 10,000 random files are renamed into random directories.
- **truncate:** 2,000 × 1 MiB files, each `ftruncate`d at a random offset inside a block
  and fsync'd. ZFS logs this as TX_SETATTR with a size change. Replay frees the tail
  and zeroes the rest of the new last block.
- **clone:** 2,000 source and 2,000 destination 1 MiB files. `copy_file_range` clones
  4 aligned 128K blocks of each source into its destination. Replay must read the
  destination's indirect blocks.

**Results, 3 reps** (mean ± std dev):

| Workload | base | prefetch v1 | **all** |
|---|---|---|---|
| create | 51.2 ± 0.0 s | 51.3 ± 0.1 s | **6.3 ± 0.0 s (8.1×)** |
| remove | 153.5 ± 0.2 s | 153.6 ± 0.2 s | **7.4 ± 0.3 s (20.7×)** |
| rename | 153.7 ± 0.3 s | 153.7 ± 0.1 s | **8.5 ± 0.9 s (18.1×)** |
| truncate | 103.4 ± 0.2 s | 101.8 ± 0.2 s | **8.6 ± 0.3 s (12.0×)** |
| clone | 53.6 ± 0.1 s | 53.3 ± 0.7 s | **6.1 ± 0.1 s (8.8×)** |
| write (regression check) | 253.7 s | 22.7 s | 23.0 ± 0.6 s |
| link (regression check) | 124.8 s | 5.4 s | 5.6 ± 0.3 s |

Base and v1 values for write and link come from the earlier matrix on the same images.

- **Correctness:** all 53 runs matched the digest, with zero replay errors.
- **Read counts are unchanged.** For example, remove does about 6,725 reads in every
  variant. Priming overlaps the reads; it doesn't avoid them.
- **The setattr size change was found by this benchmark.** The first all-types build
  primed only TX_TRUNCATE and got 101.8 s on the truncate workload, because `ftruncate`
  is logged as TX_SETATTR. Priming TX_SETATTR size changes like truncates brought it to
  8.6 s.

### TX_WRITE and TX_LINK: port vs prefetch, image replay at 23 ms

**Method** ([`scripts/perf2.sh`](scripts/perf2.sh), driver `scripts/perf2-matrix3.sh`):
- **Build each log once on fast storage.** The pool is a 12 GiB sparse image used
  through a loop device, so its label records a disk vdev, plus a separate 1 GiB SLOG
  image. Lay out the data, sync, write a ZIL header, `zpool freeze`, run the workload,
  record a checksum of every file, and export.
- **Replay each variant from the identical image.** Copy the main image onto the slow
  target, copy the SLOG image to fast storage, drop caches, then time
  `zpool import -f` with that variant's modules. Afterwards verify the file checksum and
  count reads on the slow device.
- **Targets:**
  - **dm-delay, 23 ms:** adds 23 ms to every read. 23 ms is sc1's measured QD1 random
    16 KiB read latency (43 IOPS). Reads run concurrently, up to the backing gp3's
    limits. This models a device with high latency but high parallelism (e.g. S3-backed).
  - **sc1 (EBS cold HDD):** a 12 GiB dm-linear slice of a 500 GiB volume. Real latency,
    but also IOPS and throughput limited, which caps how much parallel priming can help.

**Workloads:**
- **TX_WRITE:** 2,000 × 1 MiB files (recordsize 128K). After the freeze, a seeded
  Python writer does 8,192 `O_DSYNC` 4 KiB `pwrite`s at random 4 KiB offsets in random
  files. That gives 8,193 records that touch 6,511 distinct blocks in 1,966 files, so
  replay must read-modify-write about 6,500 blocks.
- **TX_LINK:** 200,000 empty files. After the freeze, 10,000 random ones are hard-linked
  (10,001 records).

**dm-delay 23 ms, 3 reps** (mean ± std dev):

| Workload | base | port, priming off | port, priming on | **prefetch** |
|---|---|---|---|---|
| TX_WRITE | 253.7 ± 1.2 s | 253.5 ± 0.8 s | 40.0 ± 0.5 s (6.3×) | **22.7 ± 0.3 s (11.2×)** |
| TX_LINK | 124.8 ± 0.3 s | 124.7 ± 0.2 s | 18.1 ± 0.2 s (6.9×) | **5.4 ± 0.2 s (23.1×)** |

- **Correctness:** all 24 runs: data checksum matches, zero replay errors.
- **Read counts:** TX_WRITE did about 10,540 slow-device reads at baseline and 9,005 with
  either priming design. TX_LINK did about 5,515 in every variant.
- **Why it's faster:** priming doesn't remove reads, it overlaps them.
- **Why prefetch beats the port:** its TX_WRITE tasks issue async prefetches and don't
  hold znodes or range locks. Its TX_LINK and TX_SETATTR dnode prefetches are issued
  inline, without a taskq.

### EBS sc1, image replay, 1 rep

The same images and procedure as the 23 ms runs, replayed from a real sc1 volume. The
SLOG is on gp3.

| Workload | base | port, priming off | port, priming on | prefetch |
|---|---|---|---|---|
| TX_WRITE | 798.8 s | 803.8 s | 614.8 s (1.3×) | 624.4 s (1.3×) |
| TX_LINK | 581.0 s | 583.9 s | 382.5 s (1.5×) | 382.5 s (1.5×) |

- **Correctness:** all 8 runs: data checksum matches, zero replay errors.
- **Why sc1 gains are small:** sc1 is limited in IOPS and throughput, not only in latency.
  The baseline's effective read latency is 77–105 ms, against 23 ms measured at QD1 on
  an idle volume. Sustained load and burst credits drained by the image copies push it
  higher. Issuing the reads in parallel can't beat the device's random-read ceiling, so
  both designs land at the same limit.
- **Takeaway:** the big wins (11× TX_WRITE, 23× TX_LINK at 23 ms) need a device that has
  high latency but can serve many reads at once, such as S3-backed or network block
  storage. On an IOPS-starved device, priming still helps, but only a little.

**Earlier sc1 attempt (abandoned):** building the log directly on sc1 doesn't work. On a
frozen pool, master makes every TX_WRITE commit wait for a txg sync
(`zil_lwb_commit()`: `lrc_txg > spa_freeze_txg` leads to `txg_wait_synced()`), about 2 s
each on sc1. Building the log on fast storage and replaying the image avoids this.

### Earlier harness: freeze on the slow pool (dm-delay 5 ms)

Kept for the record. The TX_LINK numbers are valid; the TX_WRITE run is not.

#### Setup

**Host:** EC2 `m7i.4xlarge` (16 vCPU, 64 GiB), Ubuntu 24.04, kernel `7.0.0-1014-aws`,
us-east-1a. Root volume: gp3 100 GiB.

**Builds:** release builds (`./configure`, no `--enable-debug`) of baseline, port and
prefetch, each loaded in turn from its tree with `scripts/zfs.sh`. Same compiler,
config and host for all of them.

**Variants per run:**

| Label | Build | `zfs_zil_replay_prime_arc` |
|---|---|---|
| base | master | n/a |
| port-off | port | 0 |
| port | port | 1 |
| prefetch | prefetch | 1 |

Variants alternate inside each repetition: `base, port-off, port, prefetch` per workload,
3 reps.

**Procedure for each run** ([`scripts/perf.sh`](scripts/perf.sh)):
1. Reload the modules and set the tunable.
2. Create the pool: main vdev on the high-latency device, SLOG on an undelayed
   loop device (file on gp3 root). Settings: `ashift=12`, `compression=off`,
   `atime=off`.
3. Lay out data and `sync` + `zpool sync`.
4. Do an fsync'd 4K write to create the ZIL header before freezing.
5. `zpool freeze`.
6. Run the workload, which leaves records only in the ZIL.
7. `zpool export`, then drop caches.
8. Time `zpool import`. Replay is the dominant part of import.
9. Verify the replayed state and check dmesg for `ZFS replay transaction error`.

**Workloads:**
- **link (TX_LINK):** create 200,000 empty files in `a/` before the freeze. After the
  freeze, hard-link 10,000 of them, chosen at random, into `b/`, then fsync `b/`.
  That gives 10,001 ZIL records. The files are random so the target dnodes are spread
  over about 6,000 dnode blocks.
- **write (TX_WRITE):** 2,000 files laid out before the freeze. After the freeze, fio does
  8,192 sync 4 KiB random rewrites (`--sync=1`, `--file_service_type=random`) across all
  files. That gives 8,193 records. Every record partially overwrites one block, so replay
  must read that block.

**High-latency devices:**
1. **dm-delay, 5 ms:** `dmsetup ... delay` over a loop file on gp3, adding 5 ms to reads
   and nothing to writes.
2. **EBS sc1:** 500 GiB cold HDD, as the main vdev with no
   artificial delay. Write workload uses `recordsize=16k` and 128 KiB files so layout fits
   sc1 throughput.


#### dm-delay 5 ms, TX_LINK: 10,001 records, 10,000 links

| Variant | Rep 1 (s) | Rep 2 (s) | Rep 3 (s) | Mean (s) | Std dev | Speedup |
|---|---|---|---|---|---|---|
| base | 31.38 | 31.08 | 31.81 | 31.42 | 0.37 | 1.0× |
| port-off | 31.37 | 31.15 | 31.38 | 31.30 | 0.13 | 1.0× |
| port | 5.16 | 5.05 | 5.10 | 5.10 | 0.06 | 6.2× |
| prefetch | 3.52 | 4.09 | 3.87 | 3.83 | 0.29 | 8.2× |

All 10,000 links were present after every import, with zero replay errors.
`port-off` matching `base` shows the disabled feature costs nothing.

#### dm-delay 5 ms, TX_WRITE: invalid, superseded by the image replay results below

| Variant | Rep 1 (s) | Rep 2 (s) | Rep 3 (s) |
|---|---|---|---|
| base | 4.24 | 5.03 | 4.59 |
| port-off | 4.17 | 4.91 | 4.90 |
| port | 5.56 | 5.75 | 5.89 |
| prefetch | 5.40 | 4.89 | 6.56 |

**This run doesn't test the feature.** fio ran with `--openfiles=64`, so it only rewrote
64 files, about 512 distinct blocks. Device stats showed only 463 main-vdev reads during
the baseline replay. The data reads that priming targets barely existed, so these numbers
mostly show priming's overhead (about 1 s for the extra log parse). Fixed for the sc1 run
with `--openfiles=2000`.

An earlier dm-delay run had no separate SLOG. Every variant took about 52 s, because
replay was bound by reading the ZIL chain serially (8,193 log blocks × 5 ms), and the
priming pass walks the same chain. That is the expected limit: the chain can't be read
ahead, because each block's pointer to the next lives inside the block. Priming helps
when the log is on fast storage and the pool is slow, which is the production layout.

## Durability

Priming is advisory and read-only. Replay correctness never depends on it.

**What priming does:**
- Nothing in priming dirties data, assigns a tx, or touches the log. It only calls
  `dmu_prefetch_dnode()`, `dmu_prefetch_by_dnode()` (under `dnode_hold()`), and
  `zap_lookup()`.
- So priming can't change what is replayed, the replay order, or `zh_replay_seq`
  and `zl_replayed_seq`. The serial replay pass is the same code as master, and it
  still replays each record and advances the replay sequence atomically in the record's
  own tx.
- Prefetch reads go through the normal ARC and zio path, so checksums, decryption,
  and self-healing behave as on any read. A failed or dropped prefetch is ignored, and
  replay's own demand read retries it and reports any error, exactly as today.
- Prefetched buffers can be evicted before replay uses them. That only costs speed.

**Ordering and lifetime:**
- Priming runs after `zil_claim()`, once the log chain has been validated. It follows the
  same `zil_parse()` filters as replay: records older than `zh_replay_seq` or the claim
  txg are skipped.
- Directory-entry priming is a read-only `zap_lookup()` under the ZAP's normal locks.
  It can contend with replay modifying the same directory, but it doesn't wait on
  replay, and replay doesn't wait on it until the end.
- Names are found with the same layouts `zfs_replay.c` uses, and every step is
  bounded by `lrc_reclen` and `ZAP_MAXNAMELEN`. A corrupt record can't make priming
  read past the record. At worst it prefetches the wrong block.
- A prime task's `dnode_hold()` can make replay's claim of a new object fail with
  `EEXIST`, because `dnode_hold_impl(DNODE_MUST_BE_FREE)` refuses held dnodes. This
  can happen when the log frees an object and a later record re-creates the same object
  number. Replay already syncs and retries a failed record once. It now waits for its
  prime tasks before that retry, so priming can't turn this into a replay failure.
- The priming pass skips the TX_OOO `dmu_object_info()` existence check. An object that is
  gone just fails `dnode_hold()` or prefetches a free dnode slot. Nothing is created.
- Tasks may overlap the replay pass. `zil_replay()` waits for its own tasks (per-call
  `zrps_outstanding` and condition variable) before it calls `zil_destroy()` and returns.
  A task can't outlive the objset or the state on `zil_replay()`'s stack. This also fixes
  amotin's review comment about a global flag when ZILs replay in parallel.
- `dnode_hold()` running concurrently with replay creating or freeing objects is the same
  pattern existing `dmu_prefetch()` callers use, such as read-ahead.

**Failure modes:**
- If the pool suspends during priming, a task's `dnode_hold()` can block like any read.
  The drain then waits, as replay itself would. Prefetch zios are speculative, so they
  don't suspend the pool by themselves.
- Dispatch failure (`TASKQID_INVALID`) skips the prefetch and frees its argument.
- Memory is bounded: each replay waits for its taskq every 1024 dispatches, each task
  argument is about 56 bytes plus the name, and the object sets are capped at 65,536
  entries (about 2 MiB).

**Compared with the faithful port:**
- The port holds znodes (`zfs_zget`) and rangelocks from the taskq, and reads data with
  `dmu_buf_hold_array_by_bonus()`. That shares znode and inode lifetime with replay and
  needed a per-replay state and drain fix to avoid a use-after-free of
  `zr_arg`.
- The port also logs `cmn_err` warnings for objects that are legitimately missing.
- The prefetch design needs no znodes or VFS state, so this class of race doesn't exist
  there.
