#!/usr/bin/env python3
"""Per-call Apple Event timing harness for issue [#16](https://github.com/skylerwshaw/che-apple-notes-mcp/issues/16).

Drives the server binary directly over stdio (no osascript, no test client)
and reports wall time per tool call, separating:
  - first vs later Apple Event in a fresh server process
  - success vs failure

Two scenarios, each in its own freshly spawned server process:
  first-success: create_folder (ok) -> delete_folder bogus (fail) -> cleanup
  first-failure: delete_folder bogus (fail) -> create_folder (ok) -> cleanup

`list_folders` is timed first as a control: it uses the SQLite path (no Apple
Event), so it should always be fast regardless of the Apple Event behavior.

Usage:
  python3 scripts/ae-timing-harness.py [--binary PATH] [--repeat N] [--cycles N]

Notes.app must be reachable (run outside any sandbox that blocks Apple
Events). Leftover fixture folders match __CheMCPTest_* and can be cleaned
with scripts/cleanup-test-folders.sh.
"""

import argparse
import json
import queue
import subprocess
import sys
import threading
import time

BOGUS_FOLDER_ID = "x-coredata://00000000-0000-0000-0000-000000000000/ICFolder/p999999999"


class Server:
    """One spawned server process speaking newline-delimited JSON-RPC."""

    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self.lines = queue.Queue()
        self.next_id = 1
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.proc.stdout:
            self.lines.put(line)

    def request(self, method, params, timeout):
        rid = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{method} id={rid}: no response in {timeout}s")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == rid:
                return obj

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def initialize(self, timeout):
        self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "ae-timing-harness", "version": "1.0"},
            },
            timeout,
        )
        self.notify("notifications/initialized")

    def call_tool(self, name, arguments, timeout):
        """Returns (elapsed_seconds, ok, text)."""
        start = time.monotonic()
        resp = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        elapsed = time.monotonic() - start
        if "error" in resp:
            return elapsed, False, resp["error"].get("message", "")
        result = resp.get("result", {})
        content = result.get("content", [])
        text = content[0].get("text", "") if content else ""
        return elapsed, not result.get("isError", False), text

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def run_scenario(name, binary, calls, timeout):
    """calls: list of (label, tool, arguments-or-callable, expected_ok)."""
    server = Server(binary)
    rows = []
    state = {}
    try:
        start = time.monotonic()
        server.initialize(timeout)
        rows.append((name, "initialize", "-", True, True, time.monotonic() - start))
        for label, tool, arguments, expected_ok in calls:
            if callable(arguments):
                try:
                    arguments = arguments(state)
                except KeyError:
                    print(f"  skipping {label}: no created folder to act on")
                    continue
            try:
                elapsed, ok, text = server.call_tool(tool, arguments, timeout)
            except (TimeoutError, BrokenPipeError) as e:
                print(f"  {label} aborted: {e}")
                break
            rows.append((name, label, tool, expected_ok, ok, elapsed))
            if not ok:
                print(f"  {label} error text: {text[:200]}")
            if tool == "create_folder" and ok:
                state["created_id"] = json.loads(text)["id"]
    finally:
        server.close()
    return rows


def run_cycles(binary, cycles, timeout):
    """One long-lived server process running create/rename/list/delete folder
    cycles, mimicking a shared-server E2E suite. Prints the server pid so a
    wedged process can be sampled (`sample <pid> 5`) while stuck."""
    server = Server(binary)
    print(f"server pid: {server.proc.pid}", flush=True)
    rows = []
    start = time.monotonic()
    server.initialize(timeout)
    rows.append(("cycles", "initialize", "-", True, True, time.monotonic() - start))
    for i in range(cycles):
        name = f"__CheMCPTest_AECycle_{i}_{int(time.monotonic() * 1000)}__"
        created_id = None
        for label, tool, arguments in [
            (f"c{i} create", "create_folder", {"title": name}),
            (f"c{i} rename", "update_folder",
             lambda: {"id": created_id, "title": name + "r"}),
            (f"c{i} list", "list_folders", {}),
            (f"c{i} delete", "delete_folder", lambda: {"id": created_id}),
        ]:
            if callable(arguments):
                arguments = arguments()
            try:
                elapsed, ok, text = server.call_tool(tool, arguments, timeout)
            except (TimeoutError, BrokenPipeError) as e:
                print(f"  {label} WEDGED: {e}", flush=True)
                wedge_forensics(server.proc.pid)
                return rows
            rows.append(("cycles", label, tool, True, ok, elapsed))
            print(f"  {label}: {'ok' if ok else 'ERROR'} {elapsed:.2f}s", flush=True)
            if tool == "create_folder" and ok:
                created_id = json.loads(text)["id"]
    server.close()
    return rows


def wedge_forensics(server_pid):
    """While the wedge is live: stack-sample the stuck server, stack-sample
    Notes.app, and probe Notes from an independent osascript to separate
    'this process is wedged' from 'Notes is wedged for everyone'."""
    print(f"\n--- osascript probe while server {server_pid} is wedged ---", flush=True)
    t0 = time.monotonic()
    try:
        probe = subprocess.run(
            ["osascript", "-e", 'tell application "Notes" to count of folders'],
            capture_output=True, text=True, timeout=30,
        )
        print(f"count of folders -> {probe.stdout.strip() or probe.stderr.strip()} "
              f"in {time.monotonic() - t0:.2f}s", flush=True)
    except subprocess.TimeoutExpired:
        print(f"osascript probe ALSO wedged (>30s): Notes.app itself is stuck", flush=True)

    for title, pid in [("wedged server", str(server_pid))] + [
        ("Notes.app", p) for p in subprocess.run(
            ["pgrep", "-x", "Notes"], capture_output=True, text=True
        ).stdout.split()
    ]:
        print(f"\n--- sample of {title} (pid {pid}) ---", flush=True)
        out = subprocess.run(["/usr/bin/sample", pid, "3"],
                             capture_output=True, text=True)
        print(out.stdout or out.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build/debug/CheAppleNotesMCP")
    parser.add_argument("--repeat", type=int, default=1, help="runs per scenario")
    parser.add_argument("--timeout", type=float, default=120, help="per-call wait (s)")
    parser.add_argument("--cycles", type=int, default=0,
                        help="instead of the two scenarios, run N folder "
                             "create/rename/list/delete cycles through one "
                             "long-lived server process (shared-server pattern)")
    args = parser.parse_args()

    suffix = str(int(time.time()))

    scenarios = [
        ("first-success", [
            ("control (no AE)", "list_folders", {}, True),
            ("AE #1: success", "create_folder",
             {"title": f"__CheMCPTest_AETiming_A_{suffix}__"}, True),
            ("AE #2: failure", "delete_folder", {"id": BOGUS_FOLDER_ID}, False),
            ("AE #3: cleanup", "delete_folder",
             lambda s: {"id": s["created_id"]}, True),
        ]),
        ("first-failure", [
            ("control (no AE)", "list_folders", {}, True),
            ("AE #1: failure", "delete_folder", {"id": BOGUS_FOLDER_ID}, False),
            ("AE #2: success", "create_folder",
             {"title": f"__CheMCPTest_AETiming_B_{suffix}__"}, True),
            ("AE #3: cleanup", "delete_folder",
             lambda s: {"id": s["created_id"]}, True),
        ]),
    ]

    print(f"binary: {args.binary}")
    all_rows = []
    if args.cycles:
        all_rows = run_cycles(args.binary, args.cycles, args.timeout)
        print_table(all_rows)
        return
    for i in range(args.repeat):
        for name, calls in scenarios:
            label = f"{name}#{i + 1}" if args.repeat > 1 else name
            print(f"\nrunning {label} (fresh server process)...", flush=True)
            try:
                all_rows += run_scenario(label, args.binary, calls, args.timeout)
            except (TimeoutError, BrokenPipeError) as e:
                print(f"  scenario aborted: {e}")

    print_table(all_rows)


def print_table(all_rows):
    print(f"\n{'scenario':<16} {'call':<18} {'tool':<14} {'expected':<9} {'got':<6} {'seconds':>8}")
    for scenario, label, tool, expected_ok, ok, elapsed in all_rows:
        exp = "ok" if expected_ok else "error"
        got = "ok" if ok else "error"
        flag = "" if (ok == expected_ok) else "  <-- UNEXPECTED"
        print(f"{scenario:<16} {label:<18} {tool:<14} {exp:<9} {got:<6} {elapsed:>8.2f}{flag}")


if __name__ == "__main__":
    sys.exit(main())
