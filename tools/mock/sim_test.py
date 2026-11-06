#!/usr/bin/env python3
"""End-to-end test: drives yb-sim through login, library and reader against the
mock server. The PKCE challenge is read from the QR code on the first screen, so
a QR code a phone could not scan, or a wrong verifier, fails the test.

Usage: sim_test.py SIM_BINARY FONT
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

import cv2

HERE = pathlib.Path(__file__).parent
PORT = "18765"
BASE = f"http://127.0.0.1:{PORT}"
# Touch points on the simulator's 1236x1648 screen.
CODE_abc123 = ["157,1329", "617,1432", "387,1432", "100,1123", "215,1123", "330,1123"]
SUBMIT = "400,1550"
FIRST_BOOK = "618,300"
SERIAL = "618,720"
REFRESH = "700,70"


def run(sim, font, root, steps, env, wait_for_qr=False):
    out = root / "out"
    for old in out.glob("*.pgm") if out.exists() else []:
        old.unlink()
    out.mkdir(exist_ok=True)
    go = root / "go"
    go.unlink(missing_ok=True)
    args = [sim, out, root / "data", font, font]
    if wait_for_qr:
        args.append(f"wait={go}")
    proc = subprocess.Popen(list(map(str, args)) + steps, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if wait_for_qr:
        first = out / "000.pgm"
        for _ in range(100):
            if first.exists() and first.stat().st_size > 1000000:
                break
            time.sleep(0.1)
        url, _, _ = cv2.QRCodeDetector().detectAndDecode(cv2.imread(str(first), cv2.IMREAD_GRAYSCALE))
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        challenge = query["code_challenge"][0]
        assert query["code_challenge_method"] == ["S256"], url
        urllib.request.urlopen(f"{BASE}/challenge?c={challenge}").read()
        go.touch()
    log, _ = proc.communicate(timeout=120)
    assert proc.returncode == 0, log
    return log, len(list(out.glob("*.pgm")))


def main():
    sim, font = sys.argv[1], sys.argv[2]
    server = subprocess.Popen([sys.executable, str(HERE / "server.py"), PORT])
    time.sleep(1)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            config = root / "config"
            env = dict(os.environ, YB_CONFIG=str(config), YB_API_BASE=BASE, YB_OAUTH_BASE=BASE)

            # A wrong code keeps the login screen; the right one reaches the library.
            run(sim, font, root, ["272,1432", SUBMIT, *CODE_abc123, SUBMIT, FIRST_BOOK, "left", "left"],
                env, wait_for_qr=True)
            assert "token=mock-token" in config.read_text()
            assert (root / "data/books/book0.book").exists()
            assert (root / "data/library.tsv").exists()
            pos = (root / "data/books/book0.pos").read_text().split()
            assert pos != ["0", "0"], pos

            # A restart opens the saved book without a new login, at the saved page.
            log, _ = run(sim, font, root, [FIRST_BOOK], env)
            assert "metadata" not in log, log
            assert (root / "data/books/book0.pos").read_text().split() == pos

            # A serial explains itself and the app carries on.
            log, frames = run(sim, font, root, [SERIAL, "600,800"], env)
            assert "metadata/v4 failed (404)" in log, log
            assert not (root / "data/books/serial-1.book").exists()

            # A token the server rejects leads back to login.
            config.write_text(config.read_text().replace("token=mock-token", "token=bad"))
            log, _ = run(sim, font, root, [REFRESH], env)
            assert "HTTP 401" in log, log
            assert "\ntoken=\n" in "\n" + config.read_text(), "token was not cleared"
    finally:
        server.terminate()
    print("sim_test: OK")


if __name__ == "__main__":
    main()
