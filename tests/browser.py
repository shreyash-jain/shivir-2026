"""Helpers for driving the scanner in Chromium with a fake camera."""

import base64
import datetime
import json
import pathlib

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


VOLUNTEER = {"id": "v-test", "name": "Test Volunteer"}


def config_hash(assigned=True, extra_sessions=(), **extra):
    """A session covering right now, so it reads as live during the test, with
    the test volunteer assigned to it.

    The setup payload doubles as the offline fallback for a phone that cannot
    reach the server at base camp, so it can carry the whole configuration --
    which is also what lets these tests run without a server.
    """
    now = datetime.datetime.now()
    today = now.strftime("%Y-%m-%d")
    sessions = [{
        "id": "test-session", "name": "Morning prayer", "venue": "Prayer hall",
        "start": (now - datetime.timedelta(minutes=30)).strftime("%H:%M"),
        "end": (now + datetime.timedelta(minutes=90)).strftime("%H:%M")}]
    sessions.extend(extra_sessions)

    cfg = {
        "sessions": sessions,
        "sessionDays": {today: [s["id"] for s in sessions]},
        "volunteers": [VOLUNTEER],
        "assignments": ([{"volunteer_id": VOLUNTEER["id"],
                          "session_id": "test-session", "day": today}]
                        if assigned else []),
    }
    cfg.update(extra)
    return base64.b64encode(json.dumps(cfg).encode()).decode()


def launch(pw, feed):
    """Chromium with the given Y4M file standing in for the rear camera."""
    return pw.chromium.launch(args=[
        "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
        f"--use-file-for-fake-video-capture={FIXTURES / feed}"])


def open_setup(pw, feed, server, **cfg):
    """Load the app and get as far as picking who is holding the phone."""
    browser = launch(pw, feed)
    page = browser.new_context(viewport={"width": 390, "height": 844},
                               permissions=["camera"]).new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(f"{server}/#cfg={config_hash(**cfg)}")
    page.wait_for_timeout(1800)
    # A phone that already has a roll and a schedule boots straight to "who is
    # using this phone?" and never shows the setup screen. Handle both.
    if page.is_visible("#s-setup"):
        page.wait_for_selector("#startBtn:not([disabled])", timeout=10000)
        page.click("#startBtn")
        page.wait_for_timeout(400)
    page.wait_for_selector("#s-who.on", timeout=10000)
    return browser, page, errors


def pick_volunteer(page, name=None):
    """Tap your own name on the "who is using this phone?" screen."""
    page.wait_for_selector("#s-who.on", timeout=10000)
    page.click(f"#whoList .station:has-text('{name or VOLUNTEER['name']}')")
    page.wait_for_selector("#s-station.on", timeout=10000)
    page.wait_for_timeout(300)


def open_session(pw, feed, server, session="Morning prayer", **cfg):
    """Setup, pick the volunteer, then stand at their assigned session."""
    browser, page, errors = open_setup(pw, feed, server, **cfg)
    pick_volunteer(page)
    page.click(f"#stationList .station:has-text('{session}')")
    page.wait_for_timeout(2600)
    return browser, page, errors


# The old name, kept because most tests just want "a volunteer at their post".
open_station = open_session


def open_registration(pw, feed, server, **cfg):
    """As open_setup, then stand at the registration desk."""
    browser, page, errors = open_setup(pw, feed, server, **cfg)
    pick_volunteer(page)
    page.click("#stationList .station:has-text('Register a badge')")
    page.wait_for_timeout(1200)
    return browser, page, errors


def type_into_scanner(page, text):
    """Use the manual-entry sheet. Same code path a volunteer uses when a
    badge is too scratched to scan."""
    page.click("#typeBtn")
    page.wait_for_timeout(200)
    page.fill("#typeIn", text)
    page.wait_for_timeout(200)
    page.click("#typeGo")
    page.wait_for_timeout(600)
