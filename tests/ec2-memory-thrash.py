"""Page-cache thrash workload for tests/ec2-memory.nix.

Holds ANON_BYTES of anonymous memory, then runs READERS processes that read
random single pages of a file on disk that is larger than the headroom left
under the cgroup bound. Every read that misses the cache refaults from disk,
so the cgroup spends its time reclaiming and refaulting instead of making
progress.

Arguments: ANON_BYTES FILE_PATH FILE_BYTES READERS. The file is created on
first use.
"""

import os
import random
import sys

CHUNK = 1 << 20
PAGE = 4096


def ensure_file(path, size):
    if os.path.exists(path) and os.path.getsize(path) == size:
        return
    with open(path, "wb") as f:
        block = b"\x02" * CHUNK
        for _ in range(size // CHUNK):
            f.write(block)
        f.flush()
        os.fsync(f.fileno())


def read_forever(fd, pages):
    while True:
        os.pread(fd, PAGE, random.randrange(pages) * PAGE)


def main():
    anon_bytes = int(sys.argv[1])
    path = sys.argv[2]
    file_bytes = int(sys.argv[3])
    readers = int(sys.argv[4])

    ensure_file(path, file_bytes)

    anon = bytearray(anon_bytes)
    for offset in range(0, anon_bytes, PAGE):
        anon[offset] = 1
    print(f"holding {anon_bytes} bytes of anonymous memory", flush=True)

    fd = os.open(path, os.O_RDONLY)
    pages = file_bytes // PAGE
    for _ in range(readers - 1):
        if os.fork() == 0:
            read_forever(fd, pages)
    read_forever(fd, pages)


if __name__ == "__main__":
    main()
