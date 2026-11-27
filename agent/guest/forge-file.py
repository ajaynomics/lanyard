"""Private byte pipe from the sidecar. Each chunk waits for its peer so a
slow computer never queues the whole file in the pi-env connection."""
import hashlib
import os
import re
import stat
import sys

CHUNK = 1024 * 1024
LIMIT = 50 * CHUNK
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def check(condition):
    if not condition:
        raise ValueError()


def root_fd(root, create):
    parts = root.split('/')[1:]
    check(root.startswith('/') and all(part not in ('', '.', '..') for part in parts))
    fd = os.open('/', DIRECTORY)
    try:
        for i, part in enumerate(parts):
            if create and i == len(parts) - 1:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def respond(data=b'\x01'):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def receive(size):
    data = sys.stdin.buffer.read(size)
    check(len(data) == size)
    return data


def pieces(size):
    while size:
        count = min(size, CHUNK)
        yield count
        size -= count


def verified(file, size, sha):
    info = os.fstat(file.fileno())
    check(stat.S_ISREG(info.st_mode) and info.st_size == size)
    file.seek(0)
    digest = hashlib.sha256()
    for count in pieces(size):
        chunk = file.read(count)
        check(len(chunk) == count)
        digest.update(chunk)
    check(not file.read(1) and digest.hexdigest() == sha)
    file.seek(0)


def stage(dir_fd, size, sha):
    target = sha + '.bundle'
    try:
        os.stat(target, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise ValueError()
    # No named partial: even a killed pipe leaves nothing for a later call.
    fd = os.open('.', os.O_RDWR | os.O_TMPFILE, 0o600, dir_fd=dir_fd)
    with os.fdopen(fd, 'w+b') as file:
        respond()
        for count in pieces(size):
            check(file.write(receive(count)) == count)
            respond()
        check(receive(1) == b'\x01')
        file.flush()
        verified(file, size, sha)
        os.fchmod(fd, 0o444)
        # linkat follows only the kernel's fd link to this anonymous inode;
        # the destination is relative to the pinned directory and cannot exist.
        os.link('/proc/self/fd/' + str(fd), target, dst_dir_fd=dir_fd, follow_symlinks=True)


def push(dir_fd, size, sha):
    fd = os.open('push.bundle', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    with os.fdopen(fd, 'rb') as file:
        check(os.fstat(fd).st_nlink == 1)
        verified(file, size, sha)
        respond()
        for count in pieces(size):
            check(receive(1) == b'\x01')
            chunk = file.read(count)
            check(len(chunk) == count)
            respond(chunk)
        check(receive(1) == b'\x01' and not file.read(1) and os.fstat(fd).st_size == size)


def main():
    mode, root, length, sha = sys.argv[1:]
    size = int(length)
    check(mode in ('stage', 'push') and 0 < size <= LIMIT and re.fullmatch('[0-9a-f]{64}', sha))
    fd = root_fd(root, mode == 'stage')
    try:
        (stage if mode == 'stage' else push)(fd, size, sha)
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError):
        sys.exit(1)
