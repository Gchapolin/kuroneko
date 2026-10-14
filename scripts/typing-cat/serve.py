"""Serves the typing cat exporter and saves the exported frames into the app.

    python3 scripts/typing-cat/serve.py      # then open http://localhost:8765

POST /frames takes {"idle": [...], "typing": [...]} (PNG data URLs) and
replaces Sources/Kuroneko/Resources/TypingCat/idle-NN.png and typing-NN.png.
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
        clips = {name: body.get(name) or [] for name in ("idle", "typing")}
        if not all(frames and all(f.startswith(PREFIX) for f in frames) for frames in clips.values()):
            self.send_error(400, "expected idle and typing PNG data URLs")
            return
        OUT.mkdir(parents=True, exist_ok=True)
        for old in OUT.glob("*.png"):
            old.unlink()
        for name, frames in clips.items():
            for i, f in enumerate(frames):
                (OUT / f"{name}-{i:02d}.png").write_bytes(base64.b64decode(f[len(PREFIX):]))
        self.send_response(204)
        self.end_headers()


if __name__ == "__main__":
    handler = functools.partial(Handler, directory=str(HERE))
    http.server.ThreadingHTTPServer(("127.0.0.1", 8765), handler).serve_forever()
