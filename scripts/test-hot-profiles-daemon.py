"""Unfunded native host profile lifecycle. Never connects to a node or creates keys."""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="paperclip-profiles-") as temporary:
    root = Path(temporary)
    os.chmod(root, 0o700)
    profiles = ["a" * 64, "b" * 64]

    def start():
        (root / "barkd.url").unlink(missing_ok=True)
        process = subprocess.Popen([str(binary), "--datadir", str(root), "--port", "0", "--exit-on-stdin-close", "--no-logfile"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    # Windows can expose the directory entry before its private
                    # writer releases the handle. Existence is not readiness.
                    url = (root / "barkd.url").read_text().strip()
                    token = (root / "auth_token").read_text().strip()
                    if re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", url) and re.fullmatch(r"[A-Za-z0-9_-]{44}", token):
                        if request(url, token, "/api/profiles")[0] == 200:
                            return process, url, token
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.05)
            raise AssertionError("Isolated profile host failed to become readable and authenticated")
        except BaseException:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdin.close()
            raise

    def request(url, token, route, body=None, authenticated=True, method=None):
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(url + route, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, None

    def stop(process):
        process.stdin.close()
        try:
            assert process.wait(timeout=15) == 0
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise AssertionError("Profile host did not shut down")

    process, url, token = start()
    try:
        assert request(url, token, "/api/profiles", authenticated=False)[0] == 401
        assert request(url, token, "/api/profiles")[1] == {"version": 1, "profiles": []}
        for index, profile in enumerate(profiles):
            body = {"id": profile, "label": "Synthetic " + str(index)}
            assert request(url, token, "/api/profiles", body)[1] == body
            assert request(url, token, "/api/profiles", body)[1] == body
            assert request(url, token, "/api/profiles/" + profile + "/v1/wallet")[1] == {"fingerprint": None}
            assert request(url, token, "/api/profiles/" + profile + "/v1/wallet/mnemonic")[0] == 404
            directory = root / "hot-wallets" / profile
            assert (directory / "hot-wallet-profile").read_text() == profile
            assert not (directory / "mnemonic").exists()
            # The profile cannot become a standalone host with new credentials.
            child = subprocess.run([str(binary), "--datadir", str(directory), "--port", "0", "--no-logfile"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            assert child.returncode != 0
        rename = {"id": profiles[0], "label": "Renamed synthetic wallet"}
        assert request(url, token, "/api/profiles/" + profiles[0] + "/name", rename)[1] == rename
        assert request(url, token, "/api/profiles/" + "c" * 64 + "/v1/wallet")[0] == 404
        assert request(url, token, "/api/v1/wallet")[1] == {"fingerprint": None}
    finally:
        stop(process)
    process, url, token = start()
    try:
        saved = request(url, token, "/api/profiles")[1]
        assert len(saved["profiles"]) == 2
        assert saved["profiles"][0] == rename
        for profile in profiles:
            assert request(url, token, "/api/profiles/" + profile + "/v1/wallet")[1] == {"fingerprint": None}
    finally:
        stop(process)
print("PASS native host: authenticated profiles, idempotent registration, scoped empty wallets, no key creation, mnemonic disabled, standalone rejection, rename, missing-ID rejection, graceful shutdown and restart")
