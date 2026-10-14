#!/usr/bin/env python3
# Local OCR server — OvisOCR2 on mlx-vlm, behind apps/ovis_ocr.
#
#   GET  /                         -> drop page: send a file, get the Markdown back
#   GET  /health                   -> JSON {ready, loaded, busy, model, ...}
#   POST /ocr   (raw body)         -> Markdown. The body is the file: an image or a PDF.
#                                     ?pages=1-3,5  ?tables=html  ?images=1  ?format=json
#                                     X-Filename: scan.pdf   names it (optional)
#   POST /ocr   (application/json) -> {"path": "/abs/file.pdf"} or {"data": <base64>,
#                                     "filename": "x.png"}, plus the same options as keys,
#                                     and "save": true to write <name>.ocr.md beside path.
#   POST /unload                   -> drop the model now and give its memory back
#
# OvisOCR2 is an 0.8B Qwen3.5 fine-tune that turns one page image into Markdown in
# reading order: text, LaTeX formulas, HTML tables. mlx-vlm runs it on the GPU; the
# 6-bit build is byte-identical to bf16 on its model card and reads a page in a few
# seconds.
#
# The model loads on the first request and goes away after IDLE_SECS without one, so
# the server can stay up all day for the LLM tools that call it and cost ~60 MB
# while nobody does. Loading takes about a second. Generation is serialised on a
# lock: one GPU, one model, and a second page would only queue behind the first
# anyway.
#
# Tables come back from the model as HTML. Most callers here are LLMs and Markdown
# readers, so a table with no rowspan or colspan is rewritten as a pipe table;
# one with merged cells stays HTML, because a pipe table cannot hold it.
# ?tables=html keeps every table as the model wrote it.
#
# Binds 127.0.0.1 only and refuses a Host header that is not loopback, so a web
# page cannot reach it through DNS rebinding. {"path": ...} reads any file this
# user can, which is the point for local tools; it needs application/json, which a
# cross-origin page cannot send without a preflight this server never answers.
import base64
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

HOST = "127.0.0.1"
PORT = int(os.environ.get("OVIS_OCR_PORT", "8797"))
MODEL = os.environ.get("OVIS_OCR_MODEL", "mlx-community/OvisOCR2-6bit")
IDLE_SECS = float(os.environ.get("OVIS_OCR_IDLE_SECS", "600"))
MAX_PAGES = int(os.environ.get("OVIS_OCR_MAX_PAGES", "100"))
MAX_TOKENS = int(os.environ.get("OVIS_OCR_MAX_TOKENS", "16384"))
MAX_BODY = 200 * 1024 * 1024
# The model card's processor bounds. Below the floor small text is unreadable;
# above the ceiling the vision tower's token count, and the time, explodes.
MIN_PIXELS = 448 * 448
MAX_PIXELS = 2880 * 2880
PDF_DPI = 200

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE_HTML = os.path.join(HERE, "page.html")

# Verbatim from the model card. It was trained on this prompt; rewording it costs
# accuracy for nothing.
PROMPT = (
    "\nExtract all readable content from the image in natural human reading order and "
    "output the result as a single Markdown document. For charts or images, represent "
    'them using an HTML image tag: <img src="images/bbox_{left}_{top}_{right}_{bottom}.jpg" />, '
    "where left, top, right, bottom are bounding box coordinates scaled to [0, 1000). "
    "Format formulas as LaTeX. Format tables as HTML: <table>...</table>. Transcribe all "
    "other text as standard Markdown. Preserve the original text without translation or "
    "paraphrasing."
)

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif"}

_lock = threading.Lock()          # one generation at a time, and model load/unload
_state = {"model": None, "proc": None, "prompt": None, "last": 0.0,
          "busy": False, "pages_done": 0, "loaded_at": None, "error": None}


def log(msg):
    print(f"[ovis-ocr] {msg}", flush=True)


# ── model ───────────────────────────────────────────────────────────────────
def _ensure_loaded():
    if _state["model"] is not None:
        return
    t0 = time.time()
    from mlx_vlm import load
    from mlx_vlm.prompt_utils import apply_chat_template
    model, proc = load(MODEL)
    # enable_thinking=False is what the card passes; the template then emits an
    # empty <think></think> and the model goes straight to the transcription.
    _state["prompt"] = apply_chat_template(proc, model.config, PROMPT,
                                           num_images=1, enable_thinking=False)
    _state["model"], _state["proc"] = model, proc
    _state["loaded_at"] = time.time()
    log(f"loaded {MODEL} in {time.time() - t0:.1f}s")


def _unload(reason):
    if _state["model"] is None:
        return
    _state["model"] = _state["proc"] = _state["prompt"] = None
    _state["loaded_at"] = None
    try:
        import gc
        import mlx.core as mx
        gc.collect()
        mx.clear_cache()
    except Exception as e:  # memory comes back on exit regardless
        log(f"clear_cache failed: {e}")
    log(f"unloaded ({reason})")


def _idle_reaper():
    while True:
        time.sleep(15)
        if IDLE_SECS <= 0:
            continue
        with _lock:
            if _state["model"] is not None and time.time() - _state["last"] > IDLE_SECS:
                _unload(f"idle {int(IDLE_SECS)}s")


def _ocr_image_file(path):
    from mlx_vlm import generate
    _ensure_loaded()
    r = generate(_state["model"], _state["proc"], _state["prompt"], image=[path],
                 max_tokens=MAX_TOKENS, temperature=0.0, verbose=False)
    return r.text


# ── input → page images ─────────────────────────────────────────────────────
def parse_pages(spec, count):
    """'1-3,5' -> [0, 1, 2, 4] (0-based, in range, deduplicated, in order)."""
    if not spec:
        return list(range(count))
    out = []
    for part in str(spec).split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            lo = int(a) if a.strip() else 1
            hi = int(b) if b.strip() else count
        else:
            lo = hi = int(part)
        for p in range(max(lo, 1), min(hi, count) + 1):
            if p - 1 not in out:
                out.append(p - 1)
    return out


def _fit(img):
    """Scale into the processor's pixel bounds and flatten to RGB."""
    from PIL import Image
    if img.mode not in ("RGB", "L"):
        bg = Image.new("RGB", img.size, "white")
        rgba = img.convert("RGBA")
        bg.paste(rgba, mask=rgba.split()[-1])
        img = bg
    img = img.convert("RGB")
    w, h = img.size
    area = w * h
    if area > MAX_PIXELS:
        s = (MAX_PIXELS / area) ** 0.5
    elif area < MIN_PIXELS:
        s = (MIN_PIXELS / area) ** 0.5
    else:
        return img
    return img.resize((max(1, int(w * s)), max(1, int(h * s))), Image.LANCZOS)


def _open_image(data, name):
    from PIL import Image
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
        return img
    except Exception:
        pass
    # PIL has no HEIC reader; sips, which ships with macOS, does.
    ext = os.path.splitext(name or "")[1] or ".heic"
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, "in" + ext), os.path.join(d, "out.png")
        with open(src, "wb") as f:
            f.write(data)
        r = subprocess.run(["/usr/bin/sips", "-s", "format", "png", src, "--out", dst],
                           capture_output=True)
        if r.returncode != 0 or not os.path.exists(dst):
            raise ValueError(f"not an image or PDF this server can read: {name or 'body'}")
        img = Image.open(dst)
        img.load()
        return img


def page_images(data, name, pages_spec):
    """Yield (page_number, PIL image) for each page asked for."""
    if data[:5] == b"%PDF-":
        import pypdfium2 as pdfium
        pdf = pdfium.PdfDocument(data)
        try:
            idx = parse_pages(pages_spec, len(pdf))
            if len(idx) > MAX_PAGES:
                raise ValueError(f"{len(idx)} pages asked for; the limit is {MAX_PAGES} "
                                 f"(pass pages=, or raise OVIS_OCR_MAX_PAGES)")
            for i in idx:
                bitmap = pdf[i].render(scale=PDF_DPI / 72)
                yield i + 1, _fit(bitmap.to_pil())
        finally:
            pdf.close()
        return
    img = _open_image(data, name)
    frames = getattr(img, "n_frames", 1)
    if frames > 1:  # a multi-page TIFF
        for i in parse_pages(pages_spec, frames):
            img.seek(i)
            yield i + 1, _fit(img.copy())
        return
    yield 1, _fit(img)


# ── post-processing ─────────────────────────────────────────────────────────
IMG_TAG = re.compile(r'^\s*<img src="images/bbox_\d+_\d+_\d+_\d+\.jpg"\s*/>\s*$')


def drop_image_tags(md):
    return "\n\n".join(b for b in md.split("\n\n") if not IMG_TAG.match(b))


def clean_truncated_repeats(text, min_text_len=8000, max_period=200,
                            min_repeat_chars=100, min_repeat_times=5):
    """The model card's guard: a page that ran into max_tokens looping on one
    phrase keeps a single copy of the phrase instead of thousands."""
    n = len(text)
    if n < min_text_len:
        return text
    for unit in range(1, min(max_period, n - 1) + 1):
        if text[n - 1] != text[n - 1 - unit]:
            continue
        match, i = 1, n - 2
        while i >= unit and text[i] == text[i - unit]:
            match += 1
            i -= 1
        total = match + unit
        if total // unit >= min_repeat_times and total >= min_repeat_chars:
            return text[: n - total + unit] + text[n - total % unit:]
    return text


class _TableReader(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows, self.row, self.cell = [], None, None
        self.header_rows = set()
        self.spans = False
        self.in_thead = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "thead":
            self.in_thead = True
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            if a.get("rowspan", "1") != "1" or a.get("colspan", "1") != "1":
                self.spans = True
            self.cell = []
            if tag == "th" or self.in_thead:
                self.header_rows.add(len(self.rows))
        elif tag == "br" and self.cell is not None:
            self.cell.append("<br>")

    def handle_endtag(self, tag):
        if tag == "thead":
            self.in_thead = False
        elif tag in ("td", "th") and self.cell is not None and self.row is not None:
            self.row.append(" ".join("".join(self.cell).split()))
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)


def html_table_to_markdown(html):
    """A pipe table, or None when the table has merged cells it cannot hold."""
    p = _TableReader()
    p.feed(html)
    if p.spans or not p.rows:
        return None
    width = max(len(r) for r in p.rows)
    rows = [[c.replace("|", "\\|") for c in r] + [""] * (width - len(r)) for r in p.rows]
    line = lambda r: "| " + " | ".join(r) + " |"
    out = [line(rows[0]), "| " + " | ".join(["---"] * width) + " |"]
    out += [line(r) for r in rows[1:]]
    return "\n".join(out)


TABLE = re.compile(r"<table\b.*?</table>", re.S | re.I)


def tables_to_markdown(md):
    def sub(m):
        t = html_table_to_markdown(m.group(0))
        return t if t is not None else m.group(0)
    return TABLE.sub(sub, md)


def finish(md, tables="markdown", images=False):
    md = clean_truncated_repeats(md.strip())
    if not images:
        md = drop_image_tags(md)
    if tables != "html":
        md = tables_to_markdown(md)
    return md.strip()


def join_pages(pages):
    if len(pages) == 1:
        return pages[0][1]
    return "\n\n".join(f"<!-- page {n} -->\n\n{md}" for n, md in pages)


# ── the job ─────────────────────────────────────────────────────────────────
def run_ocr(data, name, opts):
    t0 = time.time()
    tables = (opts.get("tables") or "markdown").lower()
    images = str(opts.get("images", "")).lower() in ("1", "true", "yes")
    pages = []
    with _lock:
        _state["busy"] = True
        try:
            with tempfile.TemporaryDirectory() as d:
                for n, img in page_images(data, name, opts.get("pages")):
                    path = os.path.join(d, f"p{n}.png")
                    img.save(path)
                    t = time.time()
                    md = _ocr_image_file(path)
                    pages.append((n, finish(md, tables, images)))
                    _state["pages_done"] += 1
                    log(f"{name or 'body'} page {n}: {time.time() - t:.1f}s, {len(md)} chars")
        finally:
            _state["busy"] = False
            _state["last"] = time.time()
    if not pages:
        raise ValueError("no pages in range")
    return {"markdown": join_pages(pages), "pages": len(pages),
            "seconds": round(time.time() - t0, 2), "model": MODEL}


def saved_path_for(path):
    base, _ = os.path.splitext(path)
    return base + ".ocr.md"


# ── HTTP ────────────────────────────────────────────────────────────────────
LOOPBACK = {"127.0.0.1", "localhost", "[::1]"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _host_ok(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].lower()
        return host in LOOPBACK

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, "forbidden host")
        url = urlparse(self.path)
        if url.path in ("/", "/index.html"):
            try:
                with open(PAGE_HTML, "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError as e:
                return self._send(500, f"page missing: {e}")
        if url.path == "/health":
            return self._json(200, {
                "ready": True,
                "loaded": _state["model"] is not None,
                "busy": _state["busy"],
                "model": MODEL,
                "idle_secs": IDLE_SECS,
                "pages_done": _state["pages_done"],
                "idle_for": round(time.time() - _state["last"], 1) if _state["last"] else None,
            })
        self._send(404, "not found")

    def do_POST(self):
        if not self._host_ok():
            return self._send(403, "forbidden host")
        url = urlparse(self.path)
        if url.path == "/unload":
            with _lock:
                _unload("asked")
            return self._json(200, {"loaded": False})
        if url.path != "/ocr":
            return self._send(404, "not found")

        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return self._send(413, "file too large")
        body = self.rfile.read(length) if length else b""
        opts = {k: v[-1] for k, v in parse_qs(url.query).items()}
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        save_to = None
        try:
            if ctype == "application/json":
                req = json.loads(body or b"{}")
                opts.update({k: v for k, v in req.items() if k not in ("data", "path")})
                if req.get("path"):
                    path = os.path.expanduser(req["path"])
                    with open(path, "rb") as f:
                        data = f.read()
                    name = os.path.basename(path)
                    if req.get("save"):
                        save_to = saved_path_for(path)
                elif req.get("data"):
                    data = base64.b64decode(req["data"])
                    name = req.get("filename") or ""
                else:
                    return self._send(400, 'send {"path": ...} or {"data": <base64>}')
                opts.setdefault("format", "json")
            else:
                data = body
                name = unquote(self.headers.get("X-Filename") or opts.get("filename") or "")
            if not data:
                return self._send(400, "empty body: POST the file itself")
            result = run_ocr(data, name, opts)
            if save_to:
                with open(save_to, "w", encoding="utf-8") as f:
                    f.write(result["markdown"] + "\n")
                result["saved"] = save_to
        except FileNotFoundError as e:
            return self._send(404, str(e))
        except ValueError as e:
            return self._send(400, str(e))
        except Exception as e:
            log(f"ocr failed: {type(e).__name__}: {e}")
            return self._send(500, f"{type(e).__name__}: {e}")

        if opts.get("format") == "json" or "application/json" in (self.headers.get("Accept") or ""):
            return self._json(200, result)
        self._send(200, result["markdown"], "text/markdown; charset=utf-8")


def main():
    threading.Thread(target=_idle_reaper, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    log(f"listening on http://{HOST}:{PORT} (model {MODEL}, idle unload {int(IDLE_SECS)}s)")
    if os.environ.get("OVIS_OCR_PRELOAD") == "1":
        with _lock:
            _ensure_loaded()
            _state["last"] = time.time()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
