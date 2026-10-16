"""Check every GDScript with Godot's language server, including editor warnings.

Run: python tests/check_warnings.py --godot <Godot editor executable>
Uses only Python's standard library. Starts its own hidden headless editor on a
private loopback port; never connects to or closes the user's editor.
"""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.parse import unquote


class Client:
    def __init__(self, connection):
        self.connection = connection
        self.pending = b""

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        body = json.dumps(message).encode("utf-8")
        self.connection.sendall(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)

    def receive(self):
        while b"\r\n\r\n" not in self.pending:
            self._read()
        header, body = self.pending.split(b"\r\n\r\n", 1)
        size = next(int(line.split(b":", 1)[1]) for line in header.split(b"\r\n") if line.lower().startswith(b"content-length:"))
        while len(body) < size:
            self._read()
            body = self.pending.split(b"\r\n\r\n", 1)[1]
        self.pending = body[size:]
        return json.loads(body[:size])

    def _read(self):
        chunk = self.connection.recv(65536)
        if not chunk:
            raise RuntimeError("Godot language server closed the connection")
        self.pending += chunk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--report", type=Path, help="Optional JSON diagnostics report")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = sorted((*root.glob("scripts/**/*.gd"), *root.glob("tests/**/*.gd"),
                    *root.glob("addons/**/*.gd"), *root.glob("tools/**/*.gd")))
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen(
            [args.godot, "--headless", "--editor", "--path", str(root), "--lsp-port", str(port)],
            stdout=log, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        try:
            deadline = time.monotonic() + 30
            while True:
                try:
                    connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                    break
                except OSError:
                    if process.poll() is not None or time.monotonic() >= deadline:
                        log.seek(0)
                        raise RuntimeError("Language server did not start:\n" + log.read().decode(errors="replace"))
                    time.sleep(0.1)
            with connection:
                connection.settimeout(30)
                client = Client(connection)
                client.send("initialize", {"processId": os.getpid(), "rootUri": root.as_uri(), "capabilities": {}}, 1)
                while client.receive().get("id") != 1:
                    pass
                client.send("initialized", {})
                report = []
                for path in paths:
                    uri = path.as_uri()
                    client.send("textDocument/didOpen", {"textDocument": {"uri": uri, "languageId": "gdscript", "version": 1, "text": path.read_text(encoding="utf-8-sig")}})
                    deadline = time.monotonic() + 30
                    while True:
                        if time.monotonic() >= deadline:
                            raise RuntimeError("No diagnostics received for " + str(path))
                        try:
                            message = client.receive()
                        except TimeoutError as error:
                            raise RuntimeError("No diagnostics received for " + str(path)) from error
                        if message.get("method") != "textDocument/publishDiagnostics":
                            continue
                        params = message["params"]
                        if unquote(params["uri"]).lower() != unquote(uri).lower():
                            continue
                        for diagnostic in params["diagnostics"]:
                            if diagnostic.get("severity", 1) > 2:
                                continue
                            entry = {"path": path.relative_to(root).as_posix(), **diagnostic}
                            report.append(entry)
                            print(f"{entry['path']}:{diagnostic['range']['start']['line'] + 1}: {diagnostic['message']}", flush=True)
                        break
                    client.send("textDocument/didClose", {"textDocument": {"uri": uri}})
                if args.report:
                    args.report.write_text(json.dumps(report, indent=2), encoding="utf-8")
                print(f"GDScript diagnostics: {len(paths)} scripts, {len(report)} warnings/errors.")
                return int(bool(report))
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
