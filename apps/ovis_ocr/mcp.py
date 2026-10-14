#!/usr/bin/env python3
# MCP stdio bridge to the local OCR server (apps/ovis_ocr/server.py, :8797).
#
# Gives any MCP client (Claude Code, Claude Desktop, DSH, LM Studio, ...) one tool,
# `ocr_to_markdown`, which reads an image or PDF on this Mac and returns Markdown.
# The model stays in the server Hammerspoon runs; this process only forwards a
# file path, so it starts instantly and holds no memory.
#
#   claude mcp add --scope user ovis-ocr -- python3 ~/.hammerspoon/apps/ovis_ocr/mcp.py
#
# Standard library only, so any python3 runs it: it speaks newline-delimited
# JSON-RPC 2.0 on stdin/stdout, which is all the MCP stdio transport is.
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("OVIS_OCR_URL", "http://127.0.0.1:8797")
TIMEOUT = float(os.environ.get("OVIS_OCR_TIMEOUT", "900"))
PROTOCOL = "2025-06-18"

TOOL = {
    "name": "ocr_to_markdown",
    "description": (
        "Read a local image or PDF with OCR and return its content as Markdown, in reading "
        "order: headings, paragraphs, lists, tables and LaTeX formulas. Runs OvisOCR2 on this "
        "machine; nothing is uploaded. Use it for scans, screenshots, photos of documents, and "
        "PDFs whose text layer is missing or unreliable. Takes a few seconds per page. "
        "Multi-page results mark each page with <!-- page N -->."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "path": {"type": "string",
                     "description": "Absolute path to a PNG, JPEG, WebP, HEIC, TIFF or PDF file."},
            "pages": {"type": "string",
                      "description": "PDF/TIFF pages to read, 1-based, e.g. \"1-3,7\". Default: all."},
            "html_tables": {"type": "boolean",
                            "description": "Keep tables as HTML instead of Markdown pipe tables. "
                                           "Default false; tables with merged cells stay HTML anyway."},
        },
        "required": ["path"],
        "additionalProperties": False,
    },
}


def ocr(args):
    path = os.path.expanduser(str(args.get("path") or ""))
    if not path:
        return "path is required", True
    if not os.path.isabs(path):
        return f"path must be absolute, got {path!r}", True
    if not os.path.exists(path):
        return f"no such file: {path}", True
    req = {"path": path, "format": "json"}
    if args.get("pages"):
        req["pages"] = str(args["pages"])
    if args.get("html_tables"):
        req["tables"] = "html"
    http = urllib.request.Request(BASE + "/ocr", data=json.dumps(req).encode(),
                                  headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(http, timeout=TIMEOUT) as r:
            res = json.loads(r.read())
    except urllib.error.HTTPError as e:
        return f"OCR failed ({e.code}): {e.read().decode(errors='replace')}", True
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        return (f"The OCR server at {BASE} is not answering ({e}). Turn it on from the "
                "Hammerspoon hub: OCR tile, Server switch."), True
    return res.get("markdown", ""), False


def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method, id_ = msg.get("method"), msg.get("id")
    if id_ is None:               # a notification: nothing to answer
        return
    if method == "initialize":
        asked = (msg.get("params") or {}).get("protocolVersion")
        return reply(id_, {
            "protocolVersion": asked or PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "ovis-ocr", "version": "1.0.0"},
        })
    if method == "ping":
        return reply(id_, {})
    if method == "tools/list":
        return reply(id_, {"tools": [TOOL]})
    if method == "tools/call":
        p = msg.get("params") or {}
        if p.get("name") != TOOL["name"]:
            return reply(id_, error={"code": -32602, "message": f"unknown tool {p.get('name')}"})
        text, is_error = ocr(p.get("arguments") or {})
        return reply(id_, {"content": [{"type": "text", "text": text}], "isError": is_error})
    reply(id_, error={"code": -32601, "message": f"method not found: {method}"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply(None, error={"code": -32700, "message": "parse error"})
            continue
        try:
            handle(msg)
        except Exception as e:
            if msg.get("id") is not None:
                reply(msg["id"], error={"code": -32603, "message": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    main()
