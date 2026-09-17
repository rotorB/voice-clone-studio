"""Headless MLX service for the native Voice clone Studio macOS app."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path

from app import start_live_service


def acquire_lock(path: Path, parent_pid: int, instance_id: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise SystemExit("Another native backend already owns the lock file.")
    handle.seek(0)
    handle.truncate()
    json.dump(
        {"pid": os.getpid(), "parent_pid": parent_pid, "instance_id": instance_id},
        handle,
    )
    handle.flush()
    os.fsync(handle.fileno())
    return handle


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--lock-file", required=True)
    args = parser.parse_args()
    if os.getppid() != args.parent_pid:
        raise SystemExit("The parent application has already exited.")
    lock = acquire_lock(Path(args.lock_file), args.parent_pid, args.instance_id)
    try:
        print(
            f"START pid={os.getpid()} parent={args.parent_pid} instance={args.instance_id}",
            flush=True,
        )
        start_live_service(
            port=7862,
            block=True,
            parent_pid=args.parent_pid,
            instance_id=args.instance_id,
        )
    finally:
        print(f"STOP pid={os.getpid()} instance={args.instance_id}", flush=True)
        lock.close()


if __name__ == "__main__":
    main()
