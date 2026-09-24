#!/usr/bin/env python3
"""Drive the binary INTERACTIVELY under a pseudo-terminal for E2E tests.

    pty_run.py <transcript-out> <script.json> <argv...>

The environment is inherited (the caller sets HOME, SWARM_CODE_* ...), the
working directory is the caller's. Script steps, run in order, while the
child's output is continuously drained (so it never blocks on a full pty):

    {"wait": secs}                                   pump output for secs
    {"send": "text\\r"}                              type into the terminal
    {"until": path, "contains": substr, "timeout": s}  wait for file content
    {"until_out": substr, "timeout": s}              wait for terminal output

At the end the ANSI-stripped transcript is written to <transcript-out>, and
one status line is printed: "ALIVE" if the child is still running (it is
then killed), else "DEAD <wait-status>". Interactive-only code paths (the
heartbeat-driven scheduler, slash commands) are only reachable this way.
"""
import json
import os
import pty
import re
import select
import signal
import sys
import time

out_path, script_path, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
script = json.load(open(script_path))

pid, fd = pty.fork()
if pid == 0:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    os.execvp(argv[0], argv)

buf = b""


def pump(secs):
    """Drain output for up to secs; False once the child's side closed."""
    global buf
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0.0, min(0.2, end - time.time())))
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            buf += data
    return True


def text():
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", buf).decode("utf-8", "replace")


def file_has(path, needle):
    try:
        return needle in open(path, errors="replace").read()
    except OSError:
        return False


for step in script:
    if "wait" in step:
        pump(step["wait"])
    elif "send" in step:
        os.write(fd, step["send"].encode())
        pump(0.3)
    elif "until" in step:
        end = time.time() + step.get("timeout", 20)
        while time.time() < end and not file_has(step["until"], step.get("contains", "")):
            pump(0.3)
    elif "until_out" in step:
        end = time.time() + step.get("timeout", 20)
        while time.time() < end and step["until_out"] not in text():
            if not pump(0.3):
                break

try:
    wpid, status = os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    wpid, status = pid, -1
open(out_path, "w").write(text())
if wpid == 0:
    print("ALIVE")
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
else:
    print("DEAD %d" % status)
