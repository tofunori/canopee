#!/usr/bin/env python3

import argparse
import json
import os
import queue
import threading
import time
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlparse


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_STATE_FILE = os.environ.get(
    "CANOPE_IDE_SELECTION_STATE",
    "/tmp/canope_ide_selection.json",
)
DEFAULT_COMMAND_FILE = Path("/tmp/canope_bridge_commands.json")
DEFAULT_RESULT_FILE = Path("/tmp/canope_bridge_command_result.json")
DEFAULT_LOG_FILE = Path(os.environ.get("CANOPE_IDE_BRIDGE_LOG", "/tmp/canope-ide-bridge.log"))
PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {
    "name": "canope-claude-ide-bridge",
    "version": "0.1.0",
}
SERVER_CAPABILITIES = {
    "logging": {},
    "prompts": {"listChanged": False},
    "resources": {"subscribe": False, "listChanged": False},
    "tools": {"listChanged": False},
}
TOOLS = [
    {
        "name": "getCurrentSelection",
        "description": "Get the current text selection in the active editor.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "getLatestSelection",
        "description": "Get the most recent text selection, even if the editor focus changed.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "getOpenEditors",
        "description": "List open editors currently available in the IDE.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "getWorkspaceFolders",
        "description": "List workspace folders open in the IDE.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "openFile",
        "description": "Open a file in the IDE.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "filePath": {"type": "string"},
                "preview": {"type": "boolean"},
                "makeFrontmost": {"type": "boolean"},
            },
            "required": ["filePath"],
            "additionalProperties": True,
        },
    },
    {
        "name": "openDiff",
        "description": "Open a diff view in the IDE.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "old_file_path": {"type": "string"},
                "new_file_path": {"type": "string"},
                "new_file_contents": {"type": "string"},
                "tab_name": {"type": "string"},
            },
            "additionalProperties": True,
        },
    },
    {
        "name": "closeAllDiffTabs",
        "description": "Close all diff tabs currently open in the IDE.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "close_tab",
        "description": "Close a tab by name.",
        "inputSchema": {
            "type": "object",
            "properties": {"tab_name": {"type": "string"}},
            "required": ["tab_name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "checkDocumentDirty",
        "description": "Check whether a document has unsaved changes.",
        "inputSchema": {
            "type": "object",
            "properties": {"filePath": {"type": "string"}},
            "required": ["filePath"],
            "additionalProperties": False,
        },
    },
    {
        "name": "saveDocument",
        "description": "Save a document with unsaved changes.",
        "inputSchema": {
            "type": "object",
            "properties": {"filePath": {"type": "string"}},
            "required": ["filePath"],
            "additionalProperties": False,
        },
    },
    {
        "name": "getDiagnostics",
        "description": "Get diagnostics for the current workspace or a specific URI.",
        "inputSchema": {
            "type": "object",
            "properties": {"uri": {"type": "string"}},
            "additionalProperties": False,
        },
    },
    {
        "name": "highlightText",
        "description": (
            "Highlight a text passage in the currently open PDF in Canopée. "
            "The text must appear verbatim in the document (copy it exactly from the paper context)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Exact text to highlight (verbatim from the PDF)"},
                "page": {"type": "integer", "description": "1-based page number (optional, searches all pages if omitted)"},
                "color": {
                    "type": "string",
                    "enum": ["yellow", "green", "blue", "pink", "orange", "red"],
                    "default": "yellow",
                    "description": "Highlight color",
                },
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "underlineText",
        "description": (
            "Underline a text passage in the currently open PDF in Canopée. "
            "The text must appear verbatim in the document."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Exact text to underline (verbatim from the PDF)"},
                "page": {"type": "integer", "description": "1-based page number (optional)"},
                "color": {
                    "type": "string",
                    "enum": ["yellow", "green", "blue", "pink", "orange", "red"],
                    "default": "red",
                    "description": "Underline color",
                },
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "strikethroughText",
        "description": (
            "Apply strikethrough to a text passage in the currently open PDF in Canopée. "
            "The text must appear verbatim in the document."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Exact text to strike through (verbatim from the PDF)"},
                "page": {"type": "integer", "description": "1-based page number (optional)"},
                "color": {
                    "type": "string",
                    "enum": ["yellow", "green", "blue", "pink", "orange", "red"],
                    "default": "red",
                    "description": "Strikethrough color",
                },
            },
            "required": ["text"],
            "additionalProperties": False,
        },
    },
]


def log_debug(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        with DEFAULT_LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(f"[{timestamp}] {message}\n")
    except OSError:
        pass


@dataclass
class Session:
    session_id: str
    events: "queue.Queue[str]" = field(default_factory=queue.Queue)
    initialized: bool = False


class BridgeState:
    def __init__(self, state_file: Path):
        self.state_file = state_file
        self.lock = threading.Lock()
        self.sessions: dict[str, Session] = {}
        self.last_notification: Optional[str] = None
        self.last_state_fingerprint: Optional[tuple[int, int]] = None

    def create_session(self) -> Session:
        session = Session(session_id=str(uuid.uuid4()))
        with self.lock:
            self.sessions[session.session_id] = session
        log_debug(f"session created id={session.session_id}")
        return session

    def remove_session(self, session_id: str) -> None:
        with self.lock:
            self.sessions.pop(session_id, None)
        log_debug(f"session removed id={session_id}")

    def session_exists(self, session_id: str) -> bool:
        with self.lock:
            return session_id in self.sessions

    def mark_initialized(self, session_id: str) -> None:
        with self.lock:
            session = self.sessions.get(session_id)
            if session is None:
                return
            session.initialized = True
            log_debug(f"session initialized id={session_id}")
            if self.last_notification is not None:
                session.events.put(self.last_notification)

    def enqueue_message(self, session_id: str, message: str) -> None:
        with self.lock:
            session = self.sessions.get(session_id)
            if session is None:
                return
            session.events.put(message)
        log_debug(f"queued response session={session_id} bytes={len(message)}")

    def dispatch_state_if_changed(self) -> None:
        try:
            stat = self.state_file.stat()
            fingerprint = (stat.st_mtime_ns, stat.st_size)
        except FileNotFoundError:
            fingerprint = (-1, -1)

        with self.lock:
            if fingerprint == self.last_state_fingerprint:
                return
            self.last_state_fingerprint = fingerprint

        notification = self._load_notification()
        if notification is None:
            return

        with self.lock:
            if notification == self.last_notification:
                return
            self.last_notification = notification
            targets = [session for session in self.sessions.values() if session.initialized]

        for session in targets:
            session.events.put(notification)
        log_debug(f"selection dispatched targets={len(targets)}")

    def current_selection_payload(self) -> dict:
        try:
            payload = json.loads(self.state_file.read_text(encoding="utf-8"))
        except FileNotFoundError:
            payload = {}
        except (OSError, json.JSONDecodeError):
            payload = {}

        selection = payload.get("selection") or {}
        start = selection.get("start") or {}
        end = selection.get("end") or {}

        file_path = str(payload.get("filePath", ""))
        text = str(payload.get("text", ""))
        normalized = {
            "filePath": file_path,
            "fileUrl": f"file://{file_path}" if file_path else "",
            "text": text,
            "selection": {
                "start": {
                    "line": int(start.get("line", 0)),
                    "character": int(start.get("character", 0)),
                },
                "end": {
                    "line": int(end.get("line", 0)),
                    "character": int(end.get("character", 0)),
                },
                "isEmpty": text == "",
            },
        }
        return normalized

    def _load_notification(self) -> Optional[str]:
        payload = self.current_selection_payload()
        selection = payload.get("selection") or {}
        start = selection.get("start") or {}
        end = selection.get("end") or {}
        if not all(key in start for key in ("line", "character")):
            return None
        if not all(key in end for key in ("line", "character")):
            return None

        message = {
            "jsonrpc": "2.0",
            "method": "selection_changed",
            "params": {
                "selection": {
                    "start": {
                        "line": int(start["line"]),
                        "character": int(start["character"]),
                    },
                    "end": {
                        "line": int(end["line"]),
                        "character": int(end["character"]),
                    },
                    "isEmpty": bool(selection.get("isEmpty", False)),
                },
                "text": str(payload.get("text", "")),
                "filePath": str(payload.get("filePath", "")),
                "fileUrl": str(payload.get("fileUrl", "")),
            },
        }
        return json.dumps(message, separators=(",", ":"))


class CanopeBridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], state_file: Path):
        super().__init__(server_address, CanopeBridgeHandler)
        self.bridge_state = BridgeState(state_file)
        self.stop_event = threading.Event()


class CanopeBridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self) -> None:
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        log_debug(f"GET {parsed.path}")
        if parsed.path == "/health":
            body = json.dumps({"status": "ok"}).encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path != "/sse":
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
            return

        session = self.server.bridge_state.create_session()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        endpoint = (
            f"http://{self.server.server_address[0]}:{self.server.server_address[1]}"
            f"/messages?sessionId={session.session_id}"
        )

        try:
            self._write_event("endpoint", endpoint)
            log_debug(f"SSE endpoint announced session={session.session_id} endpoint={endpoint}")
            self.wfile.flush()

            while not self.server.stop_event.is_set():
                try:
                    event = session.events.get(timeout=10.0)
                    log_debug(f"SSE message sent session={session.session_id} bytes={len(event)}")
                    self._write_event("message", event)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.server.bridge_state.remove_session(session.session_id)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        log_debug(f"POST {parsed.path}?{parsed.query}")
        if parsed.path != "/messages":
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
            return

        session_id = parse_qs(parsed.query).get("sessionId", [None])[0]
        if not session_id or not self.server.bridge_state.session_exists(session_id):
            self.send_error(HTTPStatus.NOT_FOUND, "Unknown session")
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        try:
            raw_body = self.rfile.read(content_length)
            message = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return

        method = message.get("method")
        request_id = message.get("id")
        log_debug(f"client message session={session_id} method={method!r} id={request_id!r}")

        response = self._handle_client_message(session_id, message)
        if response is not None:
            serialized = json.dumps(response, separators=(",", ":"))
            self.server.bridge_state.enqueue_message(session_id, serialized)

        self.send_response(HTTPStatus.ACCEPTED)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        return

    def _handle_client_message(self, session_id: str, message: dict) -> Optional[dict]:
        method = message.get("method")
        request_id = message.get("id")

        if method == "initialize":
            requested_protocol_version = (
                (message.get("params") or {}).get("protocolVersion") or PROTOCOL_VERSION
            )
            log_debug(
                f"initialize handled session={session_id} protocol={requested_protocol_version!r}"
            )
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": requested_protocol_version,
                    "capabilities": SERVER_CAPABILITIES,
                    "serverInfo": SERVER_INFO,
                },
            }

        if method == "ping":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {},
            }

        if method == "tools/list":
            log_debug(f"tools/list handled session={session_id}")
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"tools": TOOLS},
            }

        if method == "tools/call":
            name = (message.get("params") or {}).get("name")
            arguments = (message.get("params") or {}).get("arguments") or {}
            log_debug(f"tools/call handled session={session_id} name={name!r}")
            result = self._handle_tool_call(name, arguments)
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": result,
            }

        if method == "resources/list":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"resources": []},
            }

        if method == "prompts/list":
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"prompts": []},
            }

        if method == "notifications/initialized":
            self.server.bridge_state.mark_initialized(session_id)
            log_debug(f"notifications/initialized handled session={session_id}")
            return None

        if method == "ide_connected":
            log_debug(f"ide_connected handled session={session_id}")
            return None

        if request_id is None:
            return None

        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {
                "code": -32601,
                "message": f"Method not found: {method}",
            },
        }

    def _handle_tool_call(self, name: Optional[str], arguments: dict) -> dict:
        selection_payload = self.server.bridge_state.current_selection_payload()
        file_path = selection_payload["filePath"]
        file_url = selection_payload["fileUrl"]
        workspace_path = str(Path(file_path).parent) if file_path else ""
        workspace_uri = f"file://{workspace_path}" if workspace_path else ""

        if name in {"getCurrentSelection", "getLatestSelection"}:
            success = bool(file_path or selection_payload["text"])
            if success:
                text = json.dumps(
                    {
                        "success": True,
                        "text": selection_payload["text"],
                        "filePath": file_path,
                        "fileUrl": file_url,
                        "selection": selection_payload["selection"],
                    },
                    separators=(",", ":"),
                )
            else:
                text = json.dumps(
                    {"success": False, "message": "No selection available"},
                    separators=(",", ":"),
                )
            return {"content": [{"type": "text", "text": text}]}

        if name == "getOpenEditors":
            tabs = []
            if file_path:
                tabs.append(
                    {
                        "uri": file_url,
                        "isActive": True,
                        "label": Path(file_path).name,
                        "languageId": "latex",
                        "isDirty": False,
                    }
                )
            return {"content": [{"type": "text", "text": json.dumps({"tabs": tabs}, separators=(",", ":"))}]}

        if name == "getWorkspaceFolders":
            payload = {
                "success": bool(workspace_path),
                "folders": (
                    [{"name": Path(workspace_path).name, "uri": workspace_uri, "path": workspace_path}]
                    if workspace_path
                    else []
                ),
                "rootPath": workspace_path,
            }
            return {"content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}]}

        if name == "getDiagnostics":
            return {"content": [{"type": "text", "text": "[]"}]}

        if name == "checkDocumentDirty":
            payload = {
                "success": bool(arguments.get("filePath")),
                "filePath": arguments.get("filePath", ""),
                "isDirty": False,
                "isUntitled": False,
            }
            return {"content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}]}

        if name == "saveDocument":
            payload = {
                "success": bool(arguments.get("filePath")),
                "filePath": arguments.get("filePath", ""),
                "saved": bool(arguments.get("filePath")),
                "message": "Document saved successfully" if arguments.get("filePath") else "Document not open",
            }
            return {"content": [{"type": "text", "text": json.dumps(payload, separators=(",", ":"))}]}

        if name == "openFile":
            return {"content": [{"type": "text", "text": f"Opened file: {arguments.get('filePath', '')}"}]}

        if name == "openDiff":
            return {"content": [{"type": "text", "text": "DIFF_REJECTED"}]}

        if name == "closeAllDiffTabs":
            return {"content": [{"type": "text", "text": "CLOSED_0_DIFF_TABS"}]}

        if name == "close_tab":
            return {"content": [{"type": "text", "text": "TAB_CLOSED"}]}

        if name in {"highlightText", "underlineText", "strikethroughText"}:
            return self._dispatch_annotation_command(name, arguments)

        return {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(
                        {"success": False, "message": f"Unsupported tool: {name}"},
                        separators=(",", ":"),
                    ),
                }
            ],
            "isError": True,
        }

    def _dispatch_annotation_command(self, name: str, arguments: dict) -> dict:
        """Write an annotation command for the Swift app and poll for its result."""
        command_id = str(uuid.uuid4())
        command = {
            "id": command_id,
            "command": name,
            "arguments": arguments,
            "status": "pending",
        }

        # Clear any stale result
        try:
            DEFAULT_RESULT_FILE.unlink(missing_ok=True)
        except OSError:
            pass

        # Write command atomically
        tmp_path = DEFAULT_COMMAND_FILE.with_suffix(".tmp")
        try:
            tmp_path.write_text(json.dumps(command, indent=2), encoding="utf-8")
            os.replace(str(tmp_path), str(DEFAULT_COMMAND_FILE))
        except OSError as exc:
            return {
                "content": [{"type": "text", "text": f"Failed to write command: {exc}"}],
                "isError": True,
            }

        log_debug(f"annotation command dispatched id={command_id} name={name}")

        # Poll for result (up to 5 seconds)
        for _ in range(20):
            time.sleep(0.25)
            try:
                result_text = DEFAULT_RESULT_FILE.read_text(encoding="utf-8")
                result = json.loads(result_text)
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                continue

            if result.get("id") != command_id:
                continue

            status = result.get("status", "unknown")
            message = result.get("message", "")
            log_debug(f"annotation result id={command_id} status={status} message={message}")

            if status == "completed":
                return {"content": [{"type": "text", "text": message}]}
            else:
                return {
                    "content": [{"type": "text", "text": f"Error: {message}"}],
                    "isError": True,
                }

        log_debug(f"annotation command timed out id={command_id}")
        return {
            "content": [{"type": "text", "text": "Timeout: the app did not process the command within 5 seconds."}],
            "isError": True,
        }

    def _write_event(self, event_name: str, data: str) -> None:
        payload = f"event: {event_name}\n"
        for line in data.splitlines() or [""]:
            payload += f"data: {line}\n"
        payload += "\n"
        self.wfile.write(payload.encode("utf-8"))


def watch_state(server: CanopeBridgeServer, interval: float) -> None:
    while not server.stop_event.wait(interval):
        server.bridge_state.dispatch_state_if_changed()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Expose Canope LaTeX selections as a minimal MCP SSE-IDE bridge."
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE)
    parser.add_argument("--poll-interval", type=float, default=0.2)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    state_file = Path(args.state_file)
    server = CanopeBridgeServer((args.host, args.port), state_file)
    DEFAULT_LOG_FILE.write_text("", encoding="utf-8")

    watcher = threading.Thread(
        target=watch_state,
        args=(server, args.poll_interval),
        daemon=True,
    )
    watcher.start()

    print(
        f"[canope-ide-bridge] listening on http://{args.host}:{args.port}/sse",
        flush=True,
    )
    log_debug(f"bridge listening url=http://{args.host}:{args.port}/sse state_file={state_file}")
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop_event.set()
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
