"""
End-to-end scanner test. Drives the real PWA in Chromium with a fake camera
fed real QR codes rendered from the generator.

Fixtures live in conftest.py, helpers in browser.py.

Setup once:
    pip install -r tests/requirements.txt
    python -m playwright install chromium

Run:
    pytest tests/test_scanner.py -v -s
"""

from playwright.sync_api import sync_playwright

from browser import open_station


def test_participant_list_loads(server, badges):
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        p = b.new_page()
        p.goto(server)
        p.wait_for_timeout(2000)
        assert str(badges["count"]) in p.inner_text("#codeState")
        b.close()


def test_real_badge_is_recorded(server, badges):
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server)
        assert page.inner_text("#sessCount") == "1"
        assert "not" not in page.inner_text("#fWho").lower()
        assert not errors
        b.close()


def test_unpaired_badge_is_refused(server, badges):
    """A badge printed but never linked at registration must not count.

    This is a decision, not an accident: attendance is tied to a real
    person, so pairing at the desk is a prerequisite for being counted.
    See SPEC.md before changing it.
    """
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "unpaired.y4m", server)
        assert page.inner_text("#sessCount") == "0"
        assert "not linked" in page.inner_text("#fWho").lower()
        assert not errors
        b.close()


def test_forged_badge_is_refused(server, badges):
    """Regression: an IndexedDB miss once returned a truthy request object,
    so unrecognised badges were recorded as present."""
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "forged.y4m", server)
        assert page.inner_text("#sessCount") == "0", "a forged badge was recorded"
        assert "recognised" in page.inner_text("#fWho").lower()
        assert not errors
        b.close()


def test_badge_lingering_in_frame_counts_once(server, badges):
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server)
        page.wait_for_timeout(4000)          # still in view, many frames decoded
        assert page.inner_text("#sessCount") == "1", "double counted"
        assert not errors
        b.close()


def test_manual_entry_validates_offline(server, badges):
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "forged.y4m", server)
        page.click("#typeBtn")
        typo = badges["real"][:-1] + ("2" if badges["real"][-1] != "2" else "3")
        page.fill("#typeIn", typo)
        page.wait_for_timeout(300)
        hint = page.inner_text("#typeHint").lower()
        assert "check" in hint or "again" in hint, f"typo not flagged: {hint!r}"
        page.fill("#typeIn", badges["real"])
        page.wait_for_timeout(300)
        assert "good" in page.inner_text("#typeHint").lower()
        b.close()


def test_volunteer_login_offline_after_first_login(server, badges):
    """The first login has to be checked by the server. After that the phone
    remembers the volunteer, so a second login on the same phone works with
    no signal at all -- and a wrong password is still refused."""
    from browser import VOLUNTEER, open_setup
    with sync_playwright() as pw:
        b, page, errors = open_setup(pw, "blank.y4m", server)
        # Teach the phone, as a first login on wifi would.
        page.evaluate("([u,p,id,n]) => rememberVolunteer(u,p,id,n)",
                      [VOLUNTEER["username"], VOLUNTEER["password"], VOLUNTEER["id"], VOLUNTEER["name"]])

        page.fill("#loginUser", VOLUNTEER["username"])
        page.fill("#loginPass", "wrong")
        page.click("#loginGo")
        page.wait_for_timeout(600)
        assert page.is_visible("#s-who.on"), "a wrong password logged in"
        assert "wrong" in page.inner_text("#loginState").lower()

        page.fill("#loginPass", VOLUNTEER["password"])
        page.click("#loginGo")
        page.wait_for_selector("#s-station.on", timeout=5000)
        assert VOLUNTEER["name"] in page.inner_text("#stationClock")

        # Someone this phone has never seen, with no signal: told why.
        page.click("#changeWho")
        page.wait_for_timeout(300)
        page.fill("#loginUser", "stranger")
        page.fill("#loginPass", "whatever")
        page.click("#loginGo")
        page.wait_for_timeout(600)
        assert "hasn't seen you" in page.inner_text("#loginState")
        assert not errors
        b.close()
