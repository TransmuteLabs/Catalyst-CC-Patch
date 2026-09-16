#!/usr/bin/env python3
"""Run a command on a sized PTY, streaming bytes and reporting child status."""

import argparse
import errno
import fcntl
import math
import os
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time


class InstrumentError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise InstrumentError(message)


def write_status(path, line):
    if path is None:
        return
    parent = os.path.dirname(os.path.abspath(path))
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=parent, delete=False) as out:
            name = out.name
            out.write(line + "\n")
        os.replace(name, path)
        name = None
    finally:
        if name is not None:
            os.unlink(name)


def signal_group(pid, signum):
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass


def reap(pid, status):
    if status is not None:
        return status
    found, value = os.waitpid(pid, os.WNOHANG)
    return value if found else None


def stop_group(pid, status):
    # The leader may have exited while descendants still hold the PTY.
    signal_group(pid, signal.SIGTERM)
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        status = reap(pid, status)
        try:
            os.killpg(pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    signal_group(pid, signal.SIGKILL)
    if status is None:
        _, status = os.waitpid(pid, 0)
    return status


def run(args):
    pid = None
    fd = None
    child_status = None
    error_read = error_write = None
    requested = False

    def request_stop(signum, frame):
        nonlocal requested
        requested = True

    # The shell addresses the driver by its process-group id; the PTY child
    # has a separate session, so TERM must be forwarded rather than inherited.
    if os.getpgrp() != os.getpid():
        os.setsid()
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        with open(args.out, "wb", buffering=0) as capture:
            error_read, error_write = os.pipe()
            pid, fd = pty.fork()
            if pid == 0:
                try:
                    os.close(error_read)
                    capture.close()
                    signal.signal(signal.SIGTERM, signal.SIG_DFL)
                    signal.signal(signal.SIGINT, signal.SIG_DFL)
                    # Set the size before exec, not in a racing parent ioctl.
                    fcntl.ioctl(0, termios.TIOCSWINSZ,
                                struct.pack("HHHH", args.rows, args.cols, 0, 0))
                    os.execvp(args.command[0], args.command)
                except BaseException as error:
                    os.write(error_write, str(error).encode("utf-8", "replace")[:4096])
                    os._exit(127)
            os.close(error_write)
            error_write = None
            # Close-on-exec distinguishes a missing executable from exit 127.
            exec_error = os.read(error_read, 4096)
            os.close(error_read)
            error_read = None
            if exec_error:
                raise InstrumentError(exec_error.decode("utf-8", "replace"))
            deadline = time.monotonic() + args.seconds
            timed_out = False
            eof = False
            while True:
                child_status = reap(pid, child_status)
                if requested:
                    break
                if child_status is None and time.monotonic() >= deadline:
                    timed_out = True
                    break
                ready = [] if eof else select.select([fd], [], [], 0.05)[0]
                if ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        chunk = b""
                    if chunk:
                        capture.write(chunk)
                    else:
                        eof = True
                if child_status is not None and not ready:
                    break
                if eof and child_status is None:
                    time.sleep(0.02)
            child_status = stop_group(pid, child_status)
            pid = None
            if os.WIFEXITED(child_status):
                line = f"exited {os.WEXITSTATUS(child_status)}"
            else:
                line = f"signaled {os.WTERMSIG(child_status)}"
            return (1 if timed_out else 0), line
    finally:
        if pid is not None and pid > 0:
            stop_group(pid, child_status)
        for opened in (fd, error_read, error_write):
            if opened is not None:
                os.close(opened)


def main():
    status_path = None
    # Argument errors must use the status channel too, when its path is present.
    for i, value in enumerate(sys.argv[1:], 1):
        if value == "--":
            break
        if value == "--status" and i + 1 < len(sys.argv):
            status_path = sys.argv[i + 1]
        elif value.startswith("--status="):
            status_path = value.split("=", 1)[1]
    try:
        parser = Parser(description=__doc__)
        parser.add_argument("--cols", type=int, required=True)
        parser.add_argument("--rows", type=int, required=True)
        parser.add_argument("--seconds", type=float, required=True)
        parser.add_argument("--out", required=True)
        parser.add_argument("--status", required=True)
        parser.add_argument("command", nargs=argparse.REMAINDER)
        args = parser.parse_args()
        status_path = args.status
        if not args.command or args.command[0] != "--" or len(args.command) < 2:
            raise InstrumentError("command is required after --")
        args.command = args.command[1:]
        if not (1 <= args.cols <= 65535 and 1 <= args.rows <= 65535):
            raise InstrumentError("terminal dimensions must be integers from 1 to 65535")
        if not math.isfinite(args.seconds) or args.seconds < 0:
            raise InstrumentError("seconds must be finite and nonnegative")
        rc, line = run(args)
        write_status(status_path, line)
        return rc
    except (InstrumentError, OSError, ValueError) as error:
        print(f"pty-run: instrument unavailable: {error}", file=sys.stderr)
        try:
            write_status(status_path, "instrument unavailable")
        except OSError as status_error:
            print(f"pty-run: cannot write status: {status_error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
