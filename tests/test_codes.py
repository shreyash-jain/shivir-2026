"""Badge code generation. Run with: pytest tests/test_codes.py -v"""

import csv
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from make_qr_labels import ALPHABET, check_char, make_code, pretty, validate  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


def test_generated_codes_validate():
    for _ in range(2000):
        assert validate(make_code())


def test_codes_are_unique_at_scale():
    codes = {make_code() for _ in range(20000)}
    assert len(codes) > 19990, "collision rate far higher than expected"


def test_display_form_round_trips():
    c = make_code()
    for form in (pretty(c), c.lower(), f"  {pretty(c)}  ", pretty(c).lower()):
        assert validate(form), f"should accept {form!r}"


def test_ambiguous_characters_excluded():
    for ch in "01OILU":
        assert ch not in ALPHABET, f"{ch} is easy to misread and must not be used"


def test_single_substitution_detection_rate():
    """Measured, not aspirational. See CLAUDE.md for why this isn't 100%."""
    caught = total = 0
    for _ in range(200):
        c = make_code()
        for i in range(8):
            for ch in ALPHABET:
                if ch == c[i]:
                    continue
                total += 1
                if not validate(c[:i] + ch + c[i + 1:]):
                    caught += 1
    rate = caught / total
    assert rate > 0.93, f"substitution detection regressed to {rate:.2%}"


def test_transposition_detection_rate():
    caught = total = 0
    for _ in range(500):
        c = make_code()
        for i in range(7):
            if c[i] == c[i + 1]:
                continue
            total += 1
            if not validate(c[:i] + c[i + 1] + c[i] + c[i + 2:]):
                caught += 1
    rate = caught / total
    assert rate > 0.98, f"transposition detection regressed to {rate:.2%}"


def test_check_char_is_deterministic():
    body = "A2873PB"
    assert check_char(body) == check_char(body)


def test_rejects_malformed_input():
    for bad in ["", "SHORT", "A" * 9, "A2873PB!", "0000000O", None]:
        assert not validate(bad)


def test_generator_end_to_end():
    """Full run: every code in the CSV is unique and valid, and the PDF exists."""
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(
            [sys.executable, str(ROOT / "tools" / "make_qr_labels.py"),
             "--count", "300", "--out-dir", d],
            check=True, capture_output=True,
        )
        rows = list(csv.DictReader(open(pathlib.Path(d) / "codes_master.csv")))
        codes = [r["code"] for r in rows]
        assert len(codes) == 300
        assert len(set(codes)) == 300
        assert all(validate(c) for c in codes)
        assert all(r["display_code"] == pretty(r["code"]) for r in rows)
        assert (pathlib.Path(d) / "qr_labels.pdf").stat().st_size > 10_000
