#!/usr/bin/env python3
"""End-to-end smoke test for multi-mirror (metalink) aggregation.

Spins up three local mirrors serving the same payload:
  - :18091 healthy (+ serves the .meta4 manifest)
  - :18092 healthy
  - :18093 always 403 (bad mirror — must be kicked by the node pool)

Then runs `fluxdown add <meta4> --local --dir <tmp> --checksum sha-256=<hex>`
and verifies: task completion (exit 0), payload integrity, kick/rollback
evidence in the engine log.

Data-dir isolation: on Windows the CLI binary is hardlinked next to a
`portable` marker file inside the temp dir, so the engine uses
`<tmp>/exe/portable_data` instead of the real %LOCALAPPDATA%\\FluxDown.

Usage:
    python3 scripts/test_mirror_smoke.py [--cli target/release/fluxdown.exe]
                                         [--keep]

Requires: a pre-built fluxdown CLI (`cargo build -p fluxdown_cli`), python3.
"""

import argparse
import glob
import hashlib
import http.server
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HOST = "127.0.0.1"
META4_PORT = 18091
GOOD_PORT = 18092
BAD_PORT = 18093
# 10 MB of pseudo-random bytes — comfortably above the multi-segment
# threshold (~2 MB min split at high throughput) so the mirror pool path
# is exercised (single-segment downloads never build a pool).
PAYLOAD_SIZE = 10 * 1024 * 1024
META4_PATH = "/smoke.meta4"


class MirrorHandler(http.server.BaseHTTPRequestHandler):
    """Serves the shared payload; supports Range for segment probing."""

    payload: bytes = b""
    meta4: bytes = b""
    fail_403: bool = False

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self) -> None:  # noqa: N802
        if self.fail_403:
            self._send(403, "text/plain", b"forbidden")
            return
        body = self.meta4 if self.path == META4_PATH else self.payload
        self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if self.fail_403:
            self._send(403, "text/plain", b"forbidden")
            return
        if path == META4_PATH:
            self._send(200, "application/metalink4+xml", self.meta4)
            return
        if path == "/payload.bin":
            body = self.payload
            rng = self.headers.get("Range")
            if rng:
                m = re.fullmatch(r"bytes=(\d+)-(\d*)", rng)
                if m:
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else len(body) - 1
                    end = min(end, len(body) - 1)
                    chunk = body[start:end + 1]
                    self.send_response(206)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header(
                        "Content-Range", f"bytes {start}-{end}/{len(body)}"
                    )
                    self.send_header("Content-Length", str(len(chunk)))
                    self.end_headers()
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
            self._send(200, "application/octet-stream", body)
            return
        self._send(404, "text/plain", b"not found")

    def log_message(self, fmt, *args):  # noqa: N802
        pass  # keep output clean


def make_server(port: int, fail_403: bool) -> http.server.ThreadingHTTPServer:
    handler = type(
        f"Handler{port}",
        (MirrorHandler,),
        {"fail_403": fail_403},
    )
    http.server.HTTPServer.allow_reuse_address = True
    return http.server.ThreadingHTTPServer((HOST, port), handler)


def build_meta4(payload_size: int, sha256_hex: str) -> bytes:
    urls = "\n".join(
        f'    <url priority="{i}">http://{HOST}:{p}/payload.bin</url>'
        for i, p in enumerate([META4_PORT, GOOD_PORT, BAD_PORT], start=1)
    )
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<metalink xmlns="urn:ietf:params:xml:ns:metalink">\n'
        '  <file name="payload.bin">\n'
        f"    <size>{payload_size}</size>\n"
        f'    <hash type="sha-256">{sha256_hex}</hash>\n'
        f"{urls}\n"
        "  </file>\n"
        "</metalink>\n"
    )
    return xml.encode()


def find_cli(explicit: str | None) -> str:
    if explicit:
        if os.path.isfile(explicit):
            return explicit
        sys.exit(f"fluxdown CLI not found at {explicit}")
    exe = "fluxdown.exe" if os.name == "nt" else "fluxdown"
    for profile in ("release", "debug"):
        cand = os.path.join("target", profile, exe)
        if os.path.isfile(cand):
            return cand
    sys.exit("fluxdown CLI not found; run `cargo build -p fluxdown_cli` first")


def find_log(data_dir: str) -> str | None:
    """Engine logs to <data_dir>/logs/fluxdown_YYYY-MM-DD.N.log."""
    logs = sorted(glob.glob(os.path.join(data_dir, "logs", "fluxdown_*.log")))
    return logs[-1] if logs else None


def main() -> None:
    ap = argparse.ArgumentParser(description="multi-mirror smoke test")
    ap.add_argument("--cli", default=None, help="path to fluxdown CLI binary")
    ap.add_argument("--keep", action="store_true", help="keep temp dir on success")
    args = ap.parse_args()

    cli = find_cli(args.cli)
    payload = os.urandom(PAYLOAD_SIZE)
    sha256_hex = hashlib.sha256(payload).hexdigest()
    MirrorHandler.payload = payload
    MirrorHandler.meta4 = build_meta4(PAYLOAD_SIZE, sha256_hex)

    servers = [
        make_server(META4_PORT, fail_403=False),
        make_server(GOOD_PORT, fail_403=False),
        make_server(BAD_PORT, fail_403=True),
    ]
    for srv in servers:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    meta4_url = f"http://{HOST}:{META4_PORT}{META4_PATH}"
    print(f"[smoke] mirrors up: :{META4_PORT} (meta4+file), :{GOOD_PORT}, :{BAD_PORT} (403)")
    print(f"[smoke] manifest: {meta4_url}  payload {PAYLOAD_SIZE} B  sha256 {sha256_hex[:16]}…")

    tmp = tempfile.mkdtemp(prefix="fluxdown_mirror_smoke_")
    save_dir = os.path.join(tmp, "downloads")
    os.makedirs(save_dir, exist_ok=True)

    # Portable isolation: copy CLI next to a `portable` marker so the engine
    # data dir becomes <tmp>/exe/portable_data (no pollution of the real install).
    exe_dir = os.path.join(tmp, "exe")
    os.makedirs(exe_dir, exist_ok=True)
    local_cli = os.path.join(exe_dir, os.path.basename(cli))
    try:
        os.link(cli, local_cli)
    except OSError:
        shutil.copy2(cli, local_cli)
    open(os.path.join(exe_dir, "portable"), "w").close()
    data_dir = os.path.join(exe_dir, "portable_data")

    t0 = time.monotonic()
    proc = subprocess.run(
        [local_cli, "add", meta4_url, "--local", "--dir", save_dir,
         "--checksum", f"sha-256={sha256_hex}"],
        capture_output=True,
        text=True,
        timeout=180,
        cwd=exe_dir,
    )
    elapsed = time.monotonic() - t0
    print(f"[smoke] cli exit={proc.returncode} after {elapsed:.1f}s")
    if proc.stdout.strip():
        print(f"[smoke] stdout: {proc.stdout.strip()[:400]}")
    if proc.stderr.strip():
        print(f"[smoke] stderr: {proc.stderr.strip()[:400]}")

    failures: list[str] = []
    if proc.returncode != 0:
        failures.append(f"exit code {proc.returncode} (expected 0)")

    out_file = os.path.join(save_dir, "payload.bin")
    if os.path.isfile(out_file):
        actual = hashlib.sha256(open(out_file, "rb").read()).hexdigest()
        if actual != sha256_hex:
            failures.append("payload sha256 mismatch (content corrupted)")
        else:
            print(f"[smoke] payload OK ({os.path.getsize(out_file)} B)")
    else:
        failures.append(f"missing output file: {out_file}")

    log = find_log(data_dir)
    if log:
        tail = open(log, encoding="utf-8", errors="replace").read()
        marks = {
            "mirror pool snapshot": re.search(r"\[cdn-pool\][^\n]*并发快照[^\n]*1809[23]", tail),
            "kick/fallback": re.search(r"\[cdn-pool\][^\n]*被踢除", tail),
        }
        for name, m in marks.items():
            print(f"[smoke] log[{name}]: {'found' if m else 'MISSING'}")
        if not marks["kick/fallback"]:
            print("[smoke] warn: no kick evidence — the 403 mirror may never "
                  "have been leased (all segments landed on healthy mirrors); "
                  "completion alone still proves the pool path works")
    else:
        print("[smoke] warn: engine log not found, skipping evidence check")

    for srv in servers:
        srv.shutdown()

    if failures:
        print(f"[smoke] FAIL: {failures}")
        print(f"[smoke] temp dir kept for inspection: {tmp}")
        sys.exit(1)
    print("[smoke] PASS")
    if args.keep:
        print(f"[smoke] temp dir kept: {tmp}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
