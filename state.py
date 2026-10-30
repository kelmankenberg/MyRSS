#!/usr/bin/env python3
import json
import os
import secrets
import stat
import sys


def private_file(directory, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError("State must be an owned regular file without hard links.")
        os.fchmod(fd, 0o600)
        return fd
    except Exception:
        os.close(fd)
        raise


def state_directory(path):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(fd).st_uid != os.getuid():
            raise ValueError("State directory must be owned by the current user.")
        os.fchmod(fd, 0o700)
        return fd
    except Exception:
        os.close(fd)
        raise


def access_state(path, data=None):
    directory = state_directory(path)
    temporary = None
    try:
        name = os.path.basename(path)
        existing = private_file(directory, name)
        if existing is not None:
            with os.fdopen(existing, encoding="utf-8") as source:
                # Invalid existing state must never be replaced by a save.
                previous = json.load(source)
                if not isinstance(previous, dict):
                    raise ValueError("State must be a JSON object.")
        else:
            previous = {}
        if data is None:
            return previous
        if not isinstance(data, dict):
            raise ValueError("State must be a JSON object.")
        temporary = ".state-" + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(data, output, ensure_ascii=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        temporary = None
        os.fsync(directory)
        return None
    finally:
        if temporary is not None:
            os.unlink(temporary, dir_fd=directory)
        os.close(directory)


def main():
    os.umask(0o077)
    if len(sys.argv) != 3 or sys.argv[1] not in {"load", "save"}:
        raise ValueError("Usage: state.py load|save PATH")
    data = json.loads(sys.stdin.readline()) if sys.argv[1] == "save" else None
    if sys.argv[1] == "save" and not isinstance(data, dict):
        raise ValueError("State must be a JSON object.")
    result = access_state(sys.argv[2], data)
    print(json.dumps({"ok": True, "state": result}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, UnicodeError) as error:
        print(json.dumps({"ok": False, "error": str(error)[:500]}))
        sys.exit(1)
