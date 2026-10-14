"""Serves the typing cat exporter and saves the exported frames into the app.

    python3 scripts/typing-cat/serve.py      # then open http://localhost:8765

POST /frames takes {"frames": ["data:image/png;base64,...", ...]} and
replaces Sources/Kuroneko/Resources/TypingCat/cat-NN.png.
"""
import base64
import functools
import http.server
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parents[1] / "Sources" / "Kuroneko" / "Resources" / "TypingCat"
PREFIX = "data:image/png;base64,"


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/frames":
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        frames = body["frames"]
        if not frames or not all(f.startswith(PREFIX) for f in frames):
            self.send_error(400, "expected PNG data URLs")
            return
        OUT.mkdir(parents=True, exist_ok=True)
        for old in OUT.glob("cat-*.png"):
            old.unlink()
        for i, f in enumerate(frames):
            (OUT / f"cat-{i:02d}.png").write_bytes(base64.b64decode(f[len(PREFIX):]))
        self.send_response(204)
        self.end_headers()


if __name__ == "__main__":
    handler = functools.partial(Handler, directory=str(HERE))
    http.server.ThreadingHTTPServer(("127.0.0.1", 8765), handler).serve_forever()
