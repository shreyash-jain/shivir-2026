"""
Upload behaviour, against a stub PostgREST.

These tests exist because the failure modes here are silent. A scan is
confirmed from IndexedDB and the upload happens afterwards, so a wedged queue
looks exactly like a working one until the end of the day when the numbers are
wrong. What is checked:

  * one scan produces exactly one row, with the column names the schema uses
  * a phone that was offline drains when it reconnects, without duplicates
  * a syncing phone that already sent a row does not send it again
  * a server that accepts the connection and then goes silent does NOT freeze
    the queue for the rest of the day -- the CLAUDE.md invariant that the
    12-second timeout exists to protect
  * a permanent rejection is surfaced instead of retried forever

Run:
    pytest tests/test_sync.py -v -s
"""

import json
import http.server
import socketserver
import threading
import time

import pytest
from playwright.sync_api import sync_playwright

from browser import (config_hash, launch, open_registration, open_station,
                     type_into_scanner)
from test_pairing import link

STUB_PORT = 8792


class Stub:
    """Just enough PostgREST: two insert endpoints and a dedupe on uuid."""

    def __init__(self):
        self.rows = {"scans": {}, "badge_links": {}}
        self.posts = {"scans": 0, "badge_links": 0}
        self.mode = "ok"          # ok | hang | reject
        self.hang_seconds = 20

    def url(self):
        return f"http://127.0.0.1:{STUB_PORT}"


@pytest.fixture
def stub():
    s = Stub()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _cors(self):
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers",
                             "apikey,authorization,content-type,prefer,range,range-unit")
            self.send_header("Access-Control-Allow-Methods", "POST,GET,OPTIONS")

        def do_OPTIONS(self):
            self.send_response(204)
            self._cors()
            self.end_headers()

        def do_POST(self):
            table = self.path.rsplit("/", 1)[-1].split("?")[0]
            body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))

            if s.mode == "hang":
                # Accept the connection, then say nothing. This is the network
                # that hangs a fetch forever if it has no timeout.
                time.sleep(s.hang_seconds)

            if s.mode == "reject":
                self.send_response(400)
                self._cors()
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"message":"nope"}')
                return

            s.posts[table] = s.posts.get(table, 0) + 1
            for row in json.loads(body or b"[]"):
                # Prefer: resolution=ignore-duplicates -- a re-sent row is a
                # no-op, not an error.
                s.rows.setdefault(table, {}).setdefault(row["uuid"], row)

            self.send_response(201)
            self._cors()
            self.end_headers()

    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.ThreadingTCPServer(("127.0.0.1", STUB_PORT), H)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield s
    httpd.shutdown()
    httpd.server_close()


def push(page):
    """Trigger a sync now rather than waiting out the 25-second timer."""
    page.evaluate("sync()")


def wait_rows(stub, table, n, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if len(stub.rows.get(table, {})) >= n:
            return True
        time.sleep(0.25)
    return False


def cfg(stub):
    return {"supaUrl": stub.url(), "supaKey": "sb_publishable_test"}


# --------------------------------------------------------------------- tests

def test_one_scan_becomes_one_row(server, badges, stub):
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server, **cfg(stub))
        assert page.inner_text("#sessCount") == "1"
        assert wait_rows(stub, "scans", 1), "the scan never reached the server"

        (row,) = list(stub.rows["scans"].values())
        # The column names are the schema's, not the phone's internal shape.
        assert row["code"] == badges["paired"]
        assert row["session_id"] == "test-session"
        assert row["session_name"] == "Morning prayer"
        assert row["venue"] == "Prayer hall"
        assert row["source"] == "camera"
        assert row["volunteer"] == "Test Volunteer"
        assert row["scanned_at"] and row["day"] and row["dedupe"]
        assert "sessionId" not in row and "at" not in row, \
            "phone-side field names leaked into the request"
        assert not errors
        b.close()


def test_same_badge_twice_is_one_row(server, badges, stub):
    """The dedupe key is code|session|day, enforced on the phone and again by
    a unique constraint on the server."""
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server, **cfg(stub))
        page.wait_for_timeout(3500)          # badge sits in frame, many decodes
        push(page)
        page.wait_for_timeout(1500)
        assert len(stub.rows["scans"]) == 1, "the same badge produced two rows"
        assert not errors
        b.close()


def test_offline_then_reconnecting_drains_without_duplicates(server, badges, stub):
    with sync_playwright() as pw:
        b = launch(pw, "blank.y4m")
        ctx = b.new_context(viewport={"width": 390, "height": 844}, permissions=["camera"])
        page = ctx.new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))

        page.goto(f"{server}/#cfg={config_hash(**cfg(stub))}")
        page.wait_for_timeout(1800)
        page.fill("#vol", "Test Volunteer")
        page.wait_for_timeout(200)
        page.click("#startBtn")
        page.wait_for_timeout(400)

        ctx.set_offline(True)
        page.click(".station:has-text('Prayer hall')")
        page.wait_for_timeout(1500)

        # Unlinked badges are refused, so they must not join the queue either.
        for code in badges["spares"][:3]:
            type_into_scanner(page, code)
        type_into_scanner(page, badges["paired"])
        assert page.inner_text("#sessCount") == "1"
        assert stub.rows["scans"] == {}, "something was sent while offline"

        ctx.set_offline(False)
        page.evaluate("window.dispatchEvent(new Event('online'))")
        assert wait_rows(stub, "scans", 1), "the queue did not drain on reconnect"

        # And a second pass must not re-send what already went.
        push(page)
        page.wait_for_timeout(1200)
        assert len(stub.rows["scans"]) == 1
        assert not errors
        b.close()


def test_a_sent_scan_is_not_sent_again(server, badges, stub):
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server, **cfg(stub))
        assert wait_rows(stub, "scans", 1)
        first = stub.posts["scans"]

        for _ in range(3):
            push(page)
            page.wait_for_timeout(500)

        assert stub.posts["scans"] == first, \
            "the phone kept re-posting rows the server already had"
        assert not errors
        b.close()


def test_a_hung_server_does_not_freeze_the_queue(server, badges, stub):
    """A network that accepts the connection then goes silent. Without the
    explicit timeout the `syncing` guard stays true and nothing uploads for
    the rest of the day."""
    stub.mode = "hang"
    stub.hang_seconds = 20                   # longer than the 12s client timeout

    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server, **cfg(stub))
        assert page.inner_text("#sessCount") == "1", "scanning stalled on the network"
        page.wait_for_timeout(1000)

        # While the request hangs, scanning must carry on being instant.
        assert page.evaluate("syncing") is True, "expected a sync to be in flight"

        # The timeout must release the guard rather than leaving it stuck.
        page.wait_for_function("syncing === false", timeout=20000)

        stub.mode = "ok"
        push(page)
        assert wait_rows(stub, "scans", 1), \
            "the queue never recovered after a hung request"
        assert not errors
        b.close()


def test_a_permanent_rejection_is_surfaced_not_retried_forever(server, badges, stub):
    stub.mode = "reject"
    with sync_playwright() as pw:
        b, page, errors = open_station(pw, "paired.y4m", server, **cfg(stub))
        assert page.inner_text("#sessCount") == "1", "the scan was still recorded locally"
        page.wait_for_timeout(1500)
        push(page)
        page.wait_for_timeout(1500)

        page.click("#openReview")
        page.wait_for_timeout(400)
        state = page.inner_text("#syncState").lower()
        assert "rejected" in state, f"the rejection was not surfaced: {state!r}"
        assert "saved on this phone" in state, \
            "a volunteer must be told the scans are not lost"
        assert not errors
        b.close()


def test_badge_links_sync_to_their_own_table(server, badges, stub):
    """Pairing has the same queue semantics as scans, into badge_links."""
    spare = badges["spares"][0]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server, **cfg(stub))
        link(page, spare, "P950", name="Synced Person")
        push(page)
        assert wait_rows(stub, "badge_links", 1), "the pairing never reached the server"

        (row,) = list(stub.rows["badge_links"].values())
        assert row["code"] == spare
        assert row["pid"] == "P950"
        assert row["name"] == "Synced Person"
        assert row["linked_at"], "linked_at is what the server orders reissues by"
        assert "at" not in row, "phone-side field name leaked into the request"
        assert not errors
        b.close()


def test_a_reissue_names_the_badge_it_replaces(server, badges, stub):
    """The server voids the old badge from this field, so it has to be there."""
    old, new = badges["spares"][1], badges["spares"][2]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server, **cfg(stub))
        link(page, old, "P951", name="Reissued Person")
        link(page, new, "P951")
        push(page)
        assert wait_rows(stub, "badge_links", 2)

        rows = sorted(stub.rows["badge_links"].values(), key=lambda r: r["linked_at"])
        assert rows[0]["replaces"] in (None, ""), "the first link replaced nothing"
        assert rows[1]["replaces"] == old, "the reissue did not name the old badge"
        assert rows[1]["code"] == new
        assert not errors
        b.close()
