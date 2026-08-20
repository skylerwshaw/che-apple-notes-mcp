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
  python3 scripts/ae-timing-harness.py [--binary PATH] [--repeat N] [--no-warmup]

--no-warmup sets CHE_MCP_NO_AE_WARMUP=1 so the server skips its startup
warm-up Apple Event, exposing the raw first-call cost.

Notes.app must be reachable (run outside any sandbox that blocks Apple
Events). Leftover fixture folders match __CheMCPTest_* and can be cleaned
with scripts/cleanup-test-folders.sh.
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

BOGUS_FOLDER_ID = "x-coredata://00000000-0000-0000-0000-000000000000/ICFolder/p999999999"


class Server:
    """One spawned server process speaking newline-delimited JSON-RPC."""

    def __init__(self, binary, extra_env):
        env = dict(os.environ, **extra_env)
        self.proc = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
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


def run_scenario(name, binary, calls, timeout, extra_env, settle):
    """calls: list of (label, tool, arguments-or-callable, expected_ok)."""
    server = Server(binary, extra_env)
    rows = []
    state = {}
    try:
        start = time.monotonic()
        server.initialize(timeout)
        rows.append((name, "initialize", "-", True, True, time.monotonic() - start))
        if settle:
            time.sleep(settle)  # let the server's startup warm-up finish first
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build/debug/CheAppleNotesMCP")
    parser.add_argument("--repeat", type=int, default=1, help="runs per scenario")
    parser.add_argument("--timeout", type=float, default=120, help="per-call wait (s)")
    parser.add_argument("--no-warmup", action="store_true",
                        help="set CHE_MCP_NO_AE_WARMUP=1 in the server env")
    parser.add_argument("--settle", type=float, default=0,
                        help="seconds to wait after initialize before the first "
                             "tool call (models a client that connects at startup "
                             "but calls later, after any warm-up has finished)")
    args = parser.parse_args()

    extra_env = {"CHE_MCP_NO_AE_WARMUP": "1"} if args.no_warmup else {}
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
    print(f"warm-up: {'disabled (CHE_MCP_NO_AE_WARMUP=1)' if args.no_warmup else 'server default'}")
    print(f"settle: {args.settle}s after initialize")
    all_rows = []
    for i in range(args.repeat):
        for name, calls in scenarios:
            label = f"{name}#{i + 1}" if args.repeat > 1 else name
            print(f"\nrunning {label} (fresh server process)...", flush=True)
            try:
                all_rows += run_scenario(label, args.binary, calls, args.timeout,
                                         extra_env, args.settle)
            except (TimeoutError, BrokenPipeError, KeyError) as e:
                print(f"  scenario aborted: {e}")

    print(f"\n{'scenario':<16} {'call':<18} {'tool':<14} {'expected':<9} {'got':<6} {'seconds':>8}")
    for scenario, label, tool, expected_ok, ok, elapsed in all_rows:
        exp = "ok" if expected_ok else "error"
        got = "ok" if ok else "error"
        flag = "" if (ok == expected_ok) else "  <-- UNEXPECTED"
        print(f"{scenario:<16} {label:<18} {tool:<14} {exp:<9} {got:<6} {elapsed:>8.2f}{flag}")


if __name__ == "__main__":
    sys.exit(main())
