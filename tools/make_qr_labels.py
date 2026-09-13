#!/usr/bin/env python3
"""
QR sticker sheets — cut out and paste onto existing badge designs.

Produces:
  1. codes_master.csv  - the authoritative code list. Import this into your database.
  2. qr_labels.pdf     - A4 grid of QR labels with straight guillotine cut lines.

Usage:
  python3 make_qr_labels.py --count 1150
  python3 make_qr_labels.py --count 1150 --per-person 2      # front + back of badge
  python3 make_qr_labels.py --count 1150 --qr-size 25        # smaller QR
  python3 make_qr_labels.py --names participants.csv         # print name on the label

Printing:
  Single-sided, 100% scale / "Actual size" (never fit-to-page).
  Plain paper + glue stick, or blank A4 sticker sheets for peel-and-stick.
"""

import argparse
import csv
import os
import secrets
import sys

from reportlab.graphics.barcode import qr
from reportlab.graphics.shapes import Drawing
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

# --- Code generation -------------------------------------------------------
# Crockford-style alphabet: no 0/O, no 1/I/L, no U. 30 symbols, uppercase
# alphanumeric so the QR encodes efficiently.
ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
BASE = len(ALPHABET)
BODY_LEN = 7
CODE_LEN = BODY_LEN + 1


def check_char(body):
    """Weighted mod-30 check character, so a hand-typed code validates offline."""
    return ALPHABET[sum(ALPHABET.index(c) * (i + 2) for i, c in enumerate(body)) % BASE]


def make_code():
    body = "".join(secrets.choice(ALPHABET) for _ in range(BODY_LEN))
    return body + check_char(body)


def validate(code):
    code = str(code or "").strip().upper().replace("-", "")
    if len(code) != CODE_LEN or any(c not in ALPHABET for c in code):
        return False
    return check_char(code[:BODY_LEN]) == code[BODY_LEN]


def pretty(code):
    """Human-readable form: A7K2-M9QP"""
    return f"{code[:4]}-{code[4:]}"


def generate_codes(n):
    seen, out = set(), []
    while len(out) < n:
        c = make_code()
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out


PAGE_W, PAGE_H = A4
MARGIN = 8 * mm

INK = HexColor("#000000")
MUTED = HexColor("#777777")
CUT = HexColor("#BBBBBB")

PAD = 4 * mm          # white space around the QR inside its cell
TEXT_BAND = 11 * mm   # room under the QR for the human-readable code
NAME_BAND = 8 * mm    # extra room when printing name + participant ID


def draw_qr(c, code, cx, cy, size):
    """Vector QR, centred on (cx, cy). Level H survives smudges and creases."""
    widget = qr.QrCodeWidget(code, barLevel="H", barBorder=2)
    b = widget.getBounds()
    w, h = b[2] - b[0], b[3] - b[1]
    d = Drawing(size, size, transform=[size / w, 0, 0, size / h, -b[0], -b[1]])
    d.add(widget)
    d.drawOn(c, cx - size / 2, cy - size / 2)


def fit_text(c, text, font, max_size, min_size, max_width):
    size = max_size
    while size > min_size and c.stringWidth(text, font, size) > max_width:
        size -= 0.25
    return size


def draw_label(c, ox, oy, cw, ch, rec, qr_size, show_name):
    """One cell of the grid, origin at its bottom-left."""
    text_h = TEXT_BAND + (NAME_BAND if show_name else 0)
    qr_cy = oy + text_h + (ch - text_h - PAD) / 2

    draw_qr(c, rec["code"], ox + cw / 2, qr_cy, qr_size)

    c.setFillColor(INK)
    c.setFont("Courier-Bold", 8.5)
    c.drawCentredString(ox + cw / 2, oy + text_h - 5 * mm, pretty(rec["code"]))

    if show_name and rec["name"]:
        size = fit_text(c, rec["name"], "Helvetica-Bold", 8, 4.5, cw - 4 * mm)
        c.setFont("Helvetica-Bold", size)
        c.drawCentredString(ox + cw / 2, oy + 5.4 * mm, rec["name"])
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 5.5)
        c.drawCentredString(ox + cw / 2, oy + 1.8 * mm,
                            rec["pid"] or f"#{rec['serial']:05d}")
    else:
        c.setFillColor(MUTED)
        c.setFont("Helvetica", 5.5)
        c.drawCentredString(ox + cw / 2, oy + 2.0 * mm, f"#{rec['serial']:05d}")


def draw_cut_grid(c, gx, gy, cw, ch, cols, rows):
    """Continuous straight lines across the whole grid — one pass per guillotine cut."""
    c.setStrokeColor(CUT)
    c.setLineWidth(0.3)
    for i in range(cols + 1):
        x = gx + i * cw
        c.line(x, gy, x, gy + rows * ch)
    for j in range(rows + 1):
        y = gy + j * ch
        c.line(gx, y, gx + cols * cw, y)


def build_pdf(records, path, qr_size, show_name):
    cw = qr_size + 2 * PAD
    ch = qr_size + PAD + TEXT_BAND + (NAME_BAND if show_name else 0)

    usable_w, usable_h = PAGE_W - 2 * MARGIN, PAGE_H - 2 * MARGIN
    cols, rows = int(usable_w // cw), int(usable_h // ch)
    if cols < 1 or rows < 1:
        sys.exit("QR size too large to fit on A4. Try a smaller --qr-size.")
    per_sheet = cols * rows

    gx = (PAGE_W - cols * cw) / 2
    gy = (PAGE_H - rows * ch) / 2

    c = canvas.Canvas(path, pagesize=A4)
    c.setTitle("QR labels")

    for start in range(0, len(records), per_sheet):
        chunk = records[start:start + per_sheet]
        for i, rec in enumerate(chunk):
            col, row = i % cols, i // cols
            ox = gx + col * cw
            oy = gy + (rows - 1 - row) * ch
            draw_label(c, ox, oy, cw, ch, rec, qr_size, show_name)
        draw_cut_grid(c, gx, gy, cw, ch, cols, rows)

        c.setFillColor(MUTED)
        c.setFont("Helvetica", 6)
        c.drawString(MARGIN, MARGIN - 2 * mm,
                     f"#{chunk[0]['serial']:05d} - #{chunk[-1]['serial']:05d}")
        c.showPage()

    c.save()
    return cols, rows, per_sheet


ID_COLUMNS = ("participant_id", "workshop_id", "participant id", "id", "pid")


def load_roster(path):
    """Read the existing participant list. Needs a name; a participant ID is
    used to pre-link each badge so nothing has to be paired at the event."""
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit(f"No rows found in {path}")
    cols = {k.lower().strip(): k for k in rows[0].keys()}
    if "name" not in cols:
        sys.exit(f"{path} needs a 'name' column. Found: {list(rows[0].keys())}")
    idkey = next((cols[c] for c in ID_COLUMNS if c in cols), None)

    out, seen = [], set()
    for i, r in enumerate(rows, start=2):
        pid = (r[idkey] or "").strip() if idkey else ""
        if pid and pid in seen:
            sys.exit(f"Duplicate participant ID {pid!r} on row {i}. "
                     "Fix the list before printing - two badges would point at one person.")
        if pid:
            seen.add(pid)
        out.append({"name": (r[cols["name"]] or "").strip(), "pid": pid})

    if not idkey:
        print(f"Note: no participant ID column found in {path}. "
              f"Looked for {', '.join(ID_COLUMNS)}. Badges will print names only.")
    return out


def main():
    p = argparse.ArgumentParser(description="Generate cut-out QR labels.")
    p.add_argument("--count", type=int, help="Number of unique codes")
    p.add_argument("--roster", "--names", dest="roster",
                   help="Your existing participant CSV (name + participant_id). "
                        "Pre-links each badge so nothing is paired at the event.")
    p.add_argument("--spares", type=int, default=0, help="Extra unassigned codes")
    p.add_argument("--per-person", type=int, default=1,
                   help="Copies of each code, printed adjacent (use 2 for front+back)")
    p.add_argument("--qr-size", type=float, default=35.0, help="QR width in mm")
    p.add_argument("--out-dir", default="labels")
    args = p.parse_args()

    if not args.count and not args.roster:
        sys.exit("Give either --count or --roster.")

    people = load_roster(args.roster) if args.roster else []
    show_name = bool(args.roster)
    blank = {"name": "", "pid": ""}
    if args.count:
        people += [dict(blank) for _ in range(args.count)]
    people += [dict(blank) for _ in range(args.spares)]

    codes = generate_codes(len(people))
    records = [{"serial": i + 1, "code": codes[i],
                "name": people[i]["name"], "pid": people[i]["pid"]}
               for i in range(len(people))]

    # Duplicate each label in place so the copies come off the sheet together.
    sheet_records = [r for r in records for _ in range(args.per_person)]

    os.makedirs(args.out_dir, exist_ok=True)
    csv_path = os.path.join(args.out_dir, "codes_master.csv")
    pdf_path = os.path.join(args.out_dir, "qr_labels.pdf")

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["serial", "code", "display_code", "participant_id", "name", "status"])
        for r in records:
            w.writerow([r["serial"], r["code"], pretty(r["code"]), r["pid"], r["name"],
                        "linked" if r["pid"] else
                        ("named" if r["name"] else "spare")])

    cols, rows, per_sheet = build_pdf(sheet_records, pdf_path, args.qr_size * mm, show_name)

    sheets = -(-len(sheet_records) // per_sheet)
    assert all(validate(r["code"]) for r in records)
    print(f"{len(records)} codes x {args.per_person} copy/copies = {len(sheet_records)} labels")
    print(f"Grid: {cols} x {rows} = {per_sheet} per sheet -> {sheets} sheets")
    print(f"{csv_path}\n{pdf_path}")


if __name__ == "__main__":
    main()
