"""
Shared fixtures for the browser tests.

Rendering QR codes and building a fake-camera feed is slow, so it happens
once per session here rather than in each test module.

Setup once:
    pip install -r tests/requirements.txt
    python -m playwright install chromium
"""

import csv
import functools
import http.server
import pathlib
import socketserver
import subprocess
import sys
import tempfile
import threading

import cv2
import numpy as np
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCANNER = ROOT / "scanner"
FIXTURES = pathlib.Path(__file__).parent / "fixtures"
PORT = 8791

sys.path.insert(0, str(ROOT / "tools"))
from make_qr_labels import make_code  # noqa: E402


# --------------------------------------------------------------- rendering

def render_qr_png(code, out):
    """One QR as a PNG, via the same reportlab path used for the real sheets."""
    from reportlab.graphics.barcode import qr
    from reportlab.graphics.shapes import Drawing
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas

    pdf = out.with_suffix(".pdf")
    c = canvas.Canvas(str(pdf), pagesize=(60 * mm, 60 * mm))
    w = qr.QrCodeWidget(code, barLevel="H", barBorder=2)
    b = w.getBounds()
    s = 50 * mm
    d = Drawing(s, s, transform=[s / (b[2] - b[0]), 0, 0, s / (b[3] - b[1]), -b[0], -b[1]])
    d.add(w)
    d.drawOn(c, 5 * mm, 5 * mm)
    c.save()
    subprocess.run(["pdftoppm", "-png", "-r", "200", "-singlefile", str(pdf),
                    str(out.with_suffix(""))], check=True)
    return cv2.imread(str(out), cv2.IMREAD_GRAYSCALE)


def write_y4m(gray, path, frames=200):
    """A Y4M file Chromium can use as a webcam, with realistic softness."""
    W, H = 640, 480
    f = np.full((H, W), 235, np.uint8)
    f[90:390, 170:470] = cv2.resize(gray, (300, 300), interpolation=cv2.INTER_AREA)
    f = cv2.GaussianBlur(f, (3, 3), 0.6)
    yuv = cv2.cvtColor(cv2.cvtColor(f, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2YUV_I420)
    with open(path, "wb") as fh:
        fh.write(b"YUV4MPEG2 W%d H%d F25:1 Ip A1:1 C420\n" % (W, H))
        for _ in range(frames):
            fh.write(b"FRAME\n")
            fh.write(yuv.tobytes())


def write_blank_y4m(path, frames=60):
    """A camera pointed at nothing. For tests that drive the app by typing."""
    W, H = 640, 480
    f = np.full((H, W), 200, np.uint8)
    yuv = cv2.cvtColor(cv2.cvtColor(f, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2YUV_I420)
    with open(path, "wb") as fh:
        fh.write(b"YUV4MPEG2 W%d H%d F25:1 Ip A1:1 C420\n" % (W, H))
        for _ in range(frames):
            fh.write(b"FRAME\n")
            fh.write(yuv.tobytes())


# --------------------------------------------------------------- fixtures

@pytest.fixture(scope="session")
def badges():
    """A real issued badge and a forged one: valid checksum, never issued."""
    FIXTURES.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, str(ROOT / "tools" / "make_qr_labels.py"),
                        "--count", "200", "--out-dir", d], check=True, capture_output=True)
        rows = list(csv.DictReader(open(pathlib.Path(d) / "codes_master.csv")))
    issued = {r["code"] for r in rows}
    paired = rows[0]["code"]        # linked to a participant at registration
    unpaired = rows[1]["code"]      # printed but never linked

    forged = make_code()
    while forged in issued:
        forged = make_code()

    # A badge only counts at a venue once it has a participant id.
    with open(SCANNER / "codes.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["serial", "code", "display_code", "name", "pid", "status"])
        for r in rows:
            linked = r["code"] == paired
            w.writerow([r["serial"], r["code"], r["display_code"],
                        "Test Participant" if linked else "",
                        "P001" if linked else "",
                        "assigned" if linked else "unassigned"])

    for name, code in (("paired", paired), ("unpaired", unpaired), ("forged", forged)):
        write_y4m(render_qr_png(code, FIXTURES / f"{name}.png"), FIXTURES / f"{name}.y4m")
    write_blank_y4m(FIXTURES / "blank.y4m")

    yield {"paired": paired, "unpaired": unpaired, "forged": forged,
           "real": paired, "count": len(rows),
           # Printed but unlinked badges, for the registration desk to issue.
           "spares": [r["code"] for r in rows[1:8]]}
    (SCANNER / "codes.csv").unlink(missing_ok=True)


@pytest.fixture(scope="session")
def server():
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(SCANNER))
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{PORT}"
    httpd.shutdown()
