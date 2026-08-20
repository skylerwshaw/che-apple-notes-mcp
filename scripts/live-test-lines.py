#!/usr/bin/env python3
"""Collapse swift-testing console output into in-place updating lines.

Reads `swift test` output on stdin. A "◇ Test x started." line is shown as a
transient status on the current line; the matching ✔/✘ result replaces it.
Everything else passes through. With parallel testing the started/result
pairs interleave and one status line can't represent them, so this is only
wired into the serial (--no-parallel) E2E target.

swift-testing block-buffers when stdout is a pipe, which would defeat live
updates — run it under a pty, e.g.:
  script -q /dev/null swift test --no-parallel ... | python3 scripts/live-test-lines.py

When stdout is not a TTY (CI, redirect to file), acts as a plain pass-through
so logs stay clean.
"""

import sys

CLEAR = "\r\033[2K"


def main():
    out = sys.stdout
    if not out.isatty():
        for line in sys.stdin:
            out.write(line)
            out.flush()
        return

    pending = False  # a transient "started" line is currently displayed
    for line in sys.stdin:
        line = line.rstrip("\r\n")
        if not line and pending:
            continue  # pty adds blank artifacts; don't disturb the status line
        if line.startswith("◇ Test ") and line.endswith("started."):
            out.write(CLEAR + line[:-len(" started.")].strip())
            out.flush()
            pending = True
        else:
            if pending:
                out.write(CLEAR)
                pending = False
            out.write(line + "\n")
            out.flush()
    if pending:
        out.write(CLEAR)
        out.flush()


if __name__ == "__main__":
    main()
