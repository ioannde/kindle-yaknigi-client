#!/usr/bin/env python3
"""A stand-in for the Yandex Books and OAuth servers, for running yb-sim offline.

Accepts only the code "abc123" and only with the correct PKCE verifier for the
challenge the client sent, so that it fails if the client's PKCE is wrong.
Usage: server.py PORT
"""
import base64
import hashlib
import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

KEY = bytes(range(32))
IV = bytes(range(16))
CONTAINER = b'<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>'
OPF = (
    b'<package><metadata><dc:title>Mock</dc:title></metadata><manifest>'
    b'<item id="a" href="a.html"/><item id="b" href="b.html"/><item id="c" href="c.html"/>'
    b'</manifest><spine><itemref idref="a"/><itemref idref="b"/><itemref idref="c"/></spine></package>'
)
PARAGRAPH = (
    "Он шёл по длинной улице и думал о том, что прочитал накануне, а редкие "
    "прохожие оглядывались на него, не понимая, отчего он улыбается. "
)
BOOKS = 21


def encrypted(data):
    out = subprocess.run(
        ["openssl", "enc", "-aes-256-cbc", "-K", KEY.hex(), "-iv", IV.hex()],
        input=data, capture_output=True, check=True,
    ).stdout
    return list(IV + out)


def chapter(path):
    paragraphs = "".join(f"<p>{PARAGRAPH * 4}</p>" for _ in range(30))
    return f"<h1>Глава {path}</h1>{paragraphs}"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reply_json(self, code, value):
        self.reply(code, json.dumps(value).encode())

    def do_POST(self):
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        verifier = form.get("code_verifier", [""])[0]
        digest = hashlib.sha256(verifier.encode()).digest()
        challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        print(f"token request: code={form.get('code')} challenge_ok={challenge == self.server.challenge}",
              flush=True)
        if form.get("code") == ["abc123"] and challenge == self.server.challenge:
            self.reply_json(200, {"access_token": "mock-token", "refresh_token": "mock-refresh"})
        else:
            self.reply_json(400, {"error": "invalid_grant"})

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/challenge":
            # The simulator cannot scan a QR code, so the test script passes it here.
            self.server.challenge = query["c"][0]
            self.reply(200, b"")
        elif url.path.endswith("/profile/library_cards"):
            if self.headers.get("Auth-Token") != "mock-token":
                self.reply(401, b"")
                return
            page = int(query.get("page", ["1"])[0])
            start = (page - 1) * 10
            cards = [
                {
                    "uuid": f"card{i}",
                    "progress": 1,
                    "book": {
                        "uuid": f"book{i}",
                        "title": "Очень длинное название книги, которое не помещается в одну строку экрана"
                                 if i == 1 else f"Книга номер {i}",
                        "authors": [{"name": f"Автор {i}"}],
                    },
                }
                for i in range(start, min(start + 10, BOOKS))
            ]
            if page == 1:
                cards[3]["book"]["uuid"] = "serial-1"
                cards[3]["book"]["title"] = "Сериал"
            self.reply_json(200, {"library_cards": cards})
        elif "serial" in url.path:
            self.reply(404, b"")
        elif url.path.endswith("/metadata/v4"):
            self.reply_json(200, {"document_uuid": "d1", "opf": encrypted(OPF), "container": encrypted(CONTAINER)})
        elif url.path.endswith("/metadata_secret"):
            self.reply_json(200, {"secret": base64.b64encode(KEY).decode()})
        elif url.path.endswith("/content"):
            self.reply(200, chapter(query["path"][0]).encode())
        else:
            self.reply(404, b"")


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    server.challenge = None
    server.serve_forever()
