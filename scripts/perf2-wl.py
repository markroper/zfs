#!/usr/bin/env python3
"""
Workloads for perf2.sh.

  perf2-wl.py layout <workload> <dir>   before zpool freeze
  perf2-wl.py ops <workload> <dir>      after zpool freeze; logs the records
  perf2-wl.py sum <dir>                 digest of names, metadata and data

Every workload is seeded, so the same image is produced each time.
"""
import hashlib
import os
import random
import stat
import sys

NDIRS = 1000        # namespace workloads: directories ...
PERDIR = 200        # ... of this many files each (200,000 files)
NOPS = 10000        # namespace operations after the freeze
NFILES = 2000       # data workloads: files ...
FSIZE = 1 << 20     # ... of 1 MiB (8 x 128K blocks)
BLK = 128 << 10


def ns_layout(d):
    for i in range(NDIRS):
        os.mkdir("%s/d%d" % (d, i))
        for j in range(PERDIR):
            fd = os.open("%s/d%d/f%d" % (d, i, j), os.O_CREAT | os.O_WRONLY,
                         0o644)
            os.close(fd)


def data_layout(d, prefix, n):
    for i in range(n):
        with open("%s/%s%d" % (d, prefix, i), "wb") as f:
            f.write(os.urandom(FSIZE))


def fsync_dirs(d):
    for i in range(NDIRS):
        fd = os.open("%s/d%d" % (d, i), os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)


def layout(wl, d):
    if wl in ("create", "remove", "rename"):
        ns_layout(d)
    elif wl == "truncate":
        data_layout(d, "t", NFILES)
    elif wl == "clone":
        data_layout(d, "s", NFILES)
        data_layout(d, "c", NFILES)
    else:
        sys.exit("unknown workload " + wl)


def ops(wl, d):
    r = random.Random(3)
    if wl == "create":
        # New names in random directories: replay must search each
        # directory's ZAP and claim each new object's dnode.
        for n in range(NOPS):
            i = r.randrange(NDIRS)
            fd = os.open("%s/d%d/new%d" % (d, i, n),
                         os.O_CREAT | os.O_WRONLY, 0o644)
            os.close(fd)
        fsync_dirs(d)
    elif wl == "remove":
        # Random existing files: replay must look each name up and read
        # the file's dnode.
        for k in r.sample(range(NDIRS * PERDIR), NOPS):
            os.unlink("%s/d%d/f%d" % (d, k // PERDIR, k % PERDIR))
        fsync_dirs(d)
    elif wl == "rename":
        for n, k in enumerate(r.sample(range(NDIRS * PERDIR), NOPS)):
            os.rename("%s/d%d/f%d" % (d, k // PERDIR, k % PERDIR),
                      "%s/d%d/r%d" % (d, r.randrange(NDIRS), n))
        fsync_dirs(d)
    elif wl == "truncate":
        # Truncate each file inside a random block, so replay must zero
        # the rest of that block and free the blocks after it.
        for i in range(NFILES):
            fd = os.open("%s/t%d" % (d, i), os.O_WRONLY)
            os.ftruncate(fd, r.randrange(1, FSIZE // 4096) * 4096 + 1000)
            os.fsync(fd)
            os.close(fd)
    elif wl == "clone":
        # Clone 4 whole blocks from each source into the middle of its
        # copy; replay must read the copy's indirect blocks.
        for i in range(NFILES):
            src = os.open("%s/s%d" % (d, i), os.O_RDONLY)
            dst = os.open("%s/c%d" % (d, i), os.O_WRONLY)
            off = r.randrange(0, 4) * BLK
            n = os.copy_file_range(src, dst, 4 * BLK, off, off)
            assert n == 4 * BLK, n
            os.fsync(dst)
            os.close(src)
            os.close(dst)
    else:
        sys.exit("unknown workload " + wl)


def digest(d):
    h = hashlib.sha256()
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for name in sorted(dirs + files):
            p = os.path.join(root, name)
            st = os.lstat(p)
            h.update(("%s %o %d %d\n" % (os.path.relpath(p, d), st.st_mode,
                      st.st_size, st.st_nlink)).encode())
            if stat.S_ISREG(st.st_mode):
                with open(p, "rb") as f:
                    h.update(hashlib.sha256(f.read()).digest())
    return h.hexdigest()


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "layout":
        layout(sys.argv[2], sys.argv[3])
    elif cmd == "ops":
        ops(sys.argv[2], sys.argv[3])
    elif cmd == "sum":
        print(digest(sys.argv[2]))
