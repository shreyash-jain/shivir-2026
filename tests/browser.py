"""Helpers for driving the scanner in Chromium with a fake camera."""

import base64
import datetime
import json
import pathlib

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


def config_hash(**extra):
    """A session covering right now, so the station is live during the test."""
    now = datetime.datetime.now()
    cfg = {"sessions": [{
        "id": "test-session", "name": "Morning prayer", "venue": "Prayer hall",
        "start": (now - datetime.timedelta(minutes=30)).strftime("%H:%M"),
        "end": (now + datetime.timedelta(minutes=90)).strftime("%H:%M")}]}
    cfg.update(extra)
    return base64.b64encode(json.dumps(cfg).encode()).decode()


def launch(pw, feed):
    """Chromium with the given Y4M file standing in for the rear camera."""
    return pw.chromium.launch(args=[
        "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream",
        f"--use-file-for-fake-video-capture={FIXTURES / feed}"])


def open_setup(pw, feed, server, **cfg):
    """Load the app, fill in the volunteer name, stop at the station picker."""
    browser = launch(pw, feed)
    page = browser.new_context(viewport={"width": 390, "height": 844},
                               permissions=["camera"]).new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(f"{server}/#cfg={config_hash(**cfg)}")
    page.wait_for_timeout(1800)
    page.fill("#vol", "Test Volunteer")
    page.wait_for_timeout(200)
    page.click("#startBtn")
    page.wait_for_timeout(400)
    return browser, page, errors


def open_station(pw, feed, server, **cfg):
    """As open_setup, then stand at the Prayer hall venue."""
    browser, page, errors = open_setup(pw, feed, server, **cfg)
    # The station list also contains a "Register a badge" entry, so select the
    # venue by name rather than by position.
    page.click(".station:has-text('Prayer hall')")
    page.wait_for_timeout(2600)
    return browser, page, errors


def open_registration(pw, feed, server, **cfg):
    """As open_setup, then stand at the registration desk."""
    browser, page, errors = open_setup(pw, feed, server, **cfg)
    page.click(".station:has-text('Register a badge')")
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
