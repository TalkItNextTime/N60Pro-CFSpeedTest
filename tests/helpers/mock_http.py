#!/usr/bin/env python3
"""Localhost mock HTTP server for Cloudflare API integration tests."""

from __future__ import annotations

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


class ScenarioState:
    def __init__(self, scenario: dict[str, Any], request_log: Path) -> None:
        self.rules = scenario.get("rules") or []
        self.default = scenario.get("default") or {
            "status": 404,
            "json": {
                "success": False,
                "errors": [{"code": 10000, "message": "no matching mock rule"}],
            },
        }
        self.counters: dict[int, int] = {}
        self.request_log = request_log
        self.lock = threading.Lock()
        self.request_log.write_text("", encoding="utf-8")

    def _match(self, method: str, path: str, query: str, rule: dict[str, Any]) -> bool:
        if rule.get("method", method).upper() != method.upper():
            return False
        rule_path = rule.get("path")
        if rule_path is not None and path != rule_path:
            # allow prefix match when rule path has no query and request path equals
            if not path.startswith(rule_path.rstrip("/") + "/") and path != rule_path:
                return False
            if path != rule_path and not rule.get("path_prefix"):
                # exact path only unless path_prefix true
                if path != rule_path:
                    return False
        path_prefix = rule.get("path_prefix")
        if path_prefix and not path.startswith(path_prefix):
            return False
        contains = rule.get("path_contains")
        if contains and contains not in path and contains not in query:
            return False
        query_contains = rule.get("query_contains")
        if query_contains and query_contains not in query:
            return False
        return True

    def resolve(self, method: str, path: str, query: str) -> dict[str, Any]:
        with self.lock:
            for index, rule in enumerate(self.rules):
                if not self._match(method, path, query, rule):
                    continue
                if "sequence" in rule:
                    count = self.counters.get(index, 0)
                    seq = rule["sequence"]
                    item = seq[count] if count < len(seq) else seq[-1]
                    self.counters[index] = count + 1
                    return item
                return rule.get("response") or self.default
            return self.default

    def log_request(
        self,
        method: str,
        path: str,
        query: str,
        headers: dict[str, str],
        body: str,
    ) -> None:
        body_value: Any = body
        if body:
            try:
                body_value = json.loads(body)
            except json.JSONDecodeError:
                body_value = body
        entry = {
            "method": method,
            "path": path,
            "query": query,
            "headers": headers,
            "body": body_value,
        }
        # Flatten Authorization into a stable form for shell assertions.
        auth = headers.get("Authorization") or headers.get("authorization")
        if auth is not None:
            entry["Authorization"] = auth
        with self.lock:
            with self.request_log.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def make_handler(state: ScenarioState):  # type: ignore[no-untyped-def]
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
            return

        def _handle(self) -> None:
            parsed = urlparse(self.path)
            path = parsed.path
            query = parsed.query or ""
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length > 0 else b""
            try:
                body_text = raw.decode("utf-8")
            except UnicodeDecodeError:
                body_text = raw.decode("utf-8", errors="replace")

            header_map = {k: v for k, v in self.headers.items()}
            state.log_request(self.command, path, query, header_map, body_text)

            response = state.resolve(self.command, path, query)
            status = int(response.get("status", 200))
            headers = dict(response.get("headers") or {})
            if "json" in response:
                payload = json.dumps(
                    response["json"], ensure_ascii=False, separators=(",", ":")
                ).encode("utf-8")
                headers.setdefault("Content-Type", "application/json")
            elif "body" in response:
                payload = str(response["body"]).encode("utf-8")
            else:
                payload = b""

            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, str(value))
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)

        def do_GET(self) -> None:  # noqa: N802
            self._handle()

        def do_POST(self) -> None:  # noqa: N802
            self._handle()

        def do_PUT(self) -> None:  # noqa: N802
            self._handle()

        def do_DELETE(self) -> None:  # noqa: N802
            self._handle()

        def do_PATCH(self) -> None:  # noqa: N802
            self._handle()

        def do_HEAD(self) -> None:  # noqa: N802
            self._handle()

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="Cloudflare API mock HTTP server")
    parser.add_argument("--port-file", required=True, help="Write bound port here")
    parser.add_argument("--scenario", required=True, help="Scenario JSON file")
    parser.add_argument("--request-log", required=True, help="Append request JSONL here")
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    scenario_path = Path(args.scenario)
    try:
        scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"failed to load scenario: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc

    state = ScenarioState(scenario, Path(args.request_log))
    server = HTTPServer((args.host, 0), make_handler(state))
    port = server.server_address[1]
    Path(args.port_file).write_text(str(port) + "\n", encoding="utf-8")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
