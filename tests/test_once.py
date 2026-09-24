"""
Once-per-event sessions: certificate distribution over several days.

An ordinary session de-duplicates on badge|session|day. A certificate must be
given once per PERSON across the whole event, so these check that a handout
on an earlier day blocks today, that a reissued badge cannot collect again,
and that a second handout recorded offline elsewhere is surfaced, not lost.

Run:
    pytest tests/test_once.py -v -s
"""

import datetime

from playwright.sync_api import sync_playwright

from browser import VOLUNTEER, open_setup, pick_volunteer, type_into_scanner
from test_pairing import link

TODAY = datetime.date.today().isoformat()


def certs_session():
    now = datetime.datetime.now()
    return {"id": "certs", "name": "Certificates", "venue": "Desk", "once": True,
            "start": (now - datetime.timedelta(minutes=30)).strftime("%H:%M"),
            "end": (now + datetime.timedelta(minutes=90)).strftime("%H:%M")}


def cfg():
    return {"extra_sessions": [certs_session()],
            "assignments": [
                {"volunteer_id": VOLUNTEER["id"], "session_id": "test-session", "day": TODAY},
                {"volunteer_id": VOLUNTEER["id"], "session_id": "certs", "day": TODAY}]}


def at_certificates(page):
    page.click("#stationList .station:has-text('Certificates')")
    page.wait_for_timeout(1500)


def test_certificate_given_once_and_blocked_the_same_day(server, badges):
    with sync_playwright() as pw:
        b, page, errors = open_setup(pw, "blank.y4m", server, **cfg())
        pick_volunteer(page)
        assert "once per event" in page.inner_text("#stationList").lower()
        at_certificates(page)

        type_into_scanner(page, badges["paired"])
        assert page.inner_text("#sessCount") == "1"

        type_into_scanner(page, badges["paired"])
        assert "already given" in page.inner_text("#fDetail").lower()
        assert page.inner_text("#sessCount") == "1", "a second certificate was recorded"

        dedupe = page.evaluate("(async () => (await allScans()).find(s => s.sessionId==='certs').dedupe)()")
        assert dedupe == "once|P001|certs", f"keyed on the badge or the day, not the person: {dedupe}"
        assert not errors
        b.close()


def test_certificate_from_an_earlier_day_blocks_today(server, badges):
    """The whole reason for the feature: the desk runs three or four days."""
    yday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    with sync_playwright() as pw:
        b, page, errors = open_setup(pw, "blank.y4m", server, **cfg())
        # Yesterday's handout, as the server would have reported it.
        page.evaluate("""([code, yday]) => {
            ONCE.server = [["certs", "P001", code, yday + "T06:12:00.000Z", "Arpita"]];
        }""", [badges["paired"], yday])
        pick_volunteer(page)
        at_certificates(page)

        type_into_scanner(page, badges["paired"])
        detail = page.inner_text("#fDetail").lower()
        assert "already given" in detail and "arpita" in detail, detail
        assert page.inner_text("#sessCount") == "0"
        assert not errors
        b.close()


def test_a_reissued_badge_cannot_collect_again(server, badges):
    """One participant had five badges in six days. Keyed on the person, a new
    badge must not mean a new certificate."""
    spare = badges["spares"][0]
    with sync_playwright() as pw:
        b, page, errors = open_setup(pw, "blank.y4m", server, **cfg())
        pick_volunteer(page)
        at_certificates(page)
        type_into_scanner(page, badges["paired"])            # P001 collects
        assert page.inner_text("#sessCount") == "1"

        page.click("#leaveStation"); page.wait_for_timeout(400)
        page.click("#stationList .station:has-text('Register a badge')")
        page.wait_for_timeout(1000)
        label = link(page, spare, "P001")                    # P001 "lost" their badge
        assert "replace" in label.lower()

        page.click("#leaveStation"); page.wait_for_timeout(400)
        at_certificates(page)
        type_into_scanner(page, spare)
        assert "already given" in page.inner_text("#fDetail").lower(), \
            "a reissued badge collected a second certificate"
        assert page.inner_text("#sessCount") == "1"
        assert not errors
        b.close()


def test_once_sessions_show_issued_not_absent(server, badges):
    with sync_playwright() as pw:
        b, page, errors = open_setup(pw, "blank.y4m", server, **cfg())
        pick_volunteer(page)
        at_certificates(page)
        type_into_scanner(page, badges["paired"])
        page.click("#leaveStation"); page.wait_for_timeout(600)

        counts = page.inner_text("[data-counts='certs']").lower()
        assert "1 issued" in counts and "to go" in counts, counts

        page.click(".nav button[data-nav='sessions']"); page.wait_for_timeout(400)
        page.click("#sessionsList .station:has-text('Certificates')"); page.wait_for_timeout(400)
        assert page.inner_text("[data-seg=present]") == "Issued"
        assert "test participant" in page.inner_text("#listBody").lower()
        page.click("#listClose")

        # The person's own view: attendance today excludes it, certificate line shows it.
        page.click(".nav button[data-nav='people']")
        page.fill("#peopleQ", "P001"); page.wait_for_timeout(400)
        assert "0/1 today" in page.inner_text("#peopleList").lower() or \
               "absent today" in page.inner_text("#peopleList").lower(), \
            "the certificate was counted as attendance"
        page.click("#peopleList .row-p"); page.wait_for_timeout(500)
        assert "given" in page.inner_text("#personToday").lower()
        assert not errors
        b.close()
