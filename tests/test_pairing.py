"""
Registration desk: linking a spare badge to a participant.

This is the desk flow, not the queue flow. It is allowed to be slower and it
confirms explicitly, so every test here drives it the way a volunteer does --
badge, then participant id, then a deliberate tap on "Link badge".

Run:
    pytest tests/test_pairing.py -v -s
"""

from playwright.sync_api import sync_playwright

from browser import open_registration, type_into_scanner


def link(page, code, pid, name=None):
    """Badge, then participant id, then save. Returns the save button's label
    beforehand, which tells you whether the app understood this as a reissue."""
    type_into_scanner(page, code)
    type_into_scanner(page, pid)
    if name is not None:
        page.fill("#pairName", name)
        page.wait_for_timeout(150)
    label = page.inner_text("#pairSave")
    page.click("#pairSave")
    page.wait_for_timeout(600)
    return label


def go_to_venue(page):
    page.click("#leaveStation")
    page.wait_for_timeout(500)
    page.click(".station:has-text('Prayer hall')")
    page.wait_for_timeout(2000)


def test_linking_a_spare_badge_lets_it_count_at_a_venue(server, badges):
    """The whole point of the desk: an unlinked badge is refused at a venue,
    and the same badge counts once registration has linked it."""
    spare = badges["spares"][0]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server)

        link(page, spare, "P900", name="Asha Rao")
        assert page.inner_text("#sessCount") == "1"

        go_to_venue(page)
        type_into_scanner(page, spare)
        assert page.inner_text("#sessCount") == "1", "linked badge did not count"
        assert "asha rao" in page.inner_text("#fWho").lower()
        assert not errors
        b.close()


def test_badge_already_linked_to_someone_else_is_refused(server, badges):
    """And the refusal names the holder, so the volunteer can sort it out at
    the desk instead of guessing."""
    spare = badges["spares"][1]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server)

        link(page, spare, "P901", name="Ravi Kumar")

        # A different participant now presents the same badge.
        type_into_scanner(page, spare)
        assert "already in use" in page.inner_text("#fWho").lower()
        assert "ravi kumar" in page.inner_text("#fDetail").lower(), \
            "the refusal must name who holds the badge"
        assert not errors
        b.close()


def test_reissue_voids_exactly_one_badge(server, badges):
    """Somebody loses their badge. The replacement must work and the lost one
    must stop working -- otherwise a lost badge is a free meal."""
    old, new = badges["spares"][2], badges["spares"][3]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server)

        link(page, old, "P902", name="Meera Nair")
        label = link(page, new, "P902")
        assert "replace" in label.lower(), \
            f"the app should have announced a reissue, button said {label!r}"

        go_to_venue(page)

        type_into_scanner(page, old)
        assert "replaced" in page.inner_text("#fWho").lower(), "void badge still works"
        assert page.inner_text("#sessCount") == "0"

        type_into_scanner(page, new)
        assert page.inner_text("#sessCount") == "1", "replacement badge did not work"
        assert "meera nair" in page.inner_text("#fWho").lower(), \
            "the name should carry across to the new badge"
        assert not errors
        b.close()


def test_reissue_does_not_void_anybody_else(server, badges):
    """`exactly one` in the line above is the part worth testing."""
    theirs, old, new = badges["spares"][4], badges["spares"][5], badges["spares"][6]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server)

        link(page, theirs, "P903", name="Unaffected Person")
        link(page, old, "P904", name="Reissued Person")
        link(page, new, "P904")

        go_to_venue(page)
        type_into_scanner(page, theirs)
        assert page.inner_text("#sessCount") == "1", "an unrelated badge was voided"
        assert not errors
        b.close()


def test_pairing_survives_reloading_the_participant_list(server, badges):
    """A registration phone that re-imports codes.csv must not silently
    unlink everyone it has paired -- those links may not have synced yet."""
    spare = badges["spares"][0]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server)
        link(page, spare, "P905", name="Persisted Person")

        # Back to setup and re-import the roll, exactly as a volunteer would
        # if told "load the updated list".
        page.click("#leaveStation")
        page.wait_for_timeout(400)
        page.click("#backSetup")
        page.wait_for_timeout(300)
        page.evaluate("""async () => {
            const text = await (await fetch('./codes.csv', {cache:'no-store'})).text();
            await loadCodes(text);
        }""")
        page.wait_for_timeout(800)

        page.click("#startBtn")
        page.wait_for_timeout(400)
        page.click(".station:has-text('Prayer hall')")
        page.wait_for_timeout(2000)

        type_into_scanner(page, spare)
        assert page.inner_text("#sessCount") == "1", \
            "re-importing the roll wiped a pairing that had not synced"
        assert not errors
        b.close()


def test_links_are_queued_for_sync(server, badges):
    """Pairing offline queues the same way scans do. With no server
    configured the queue simply grows and the review sheet says so."""
    spare = badges["spares"][1]
    with sync_playwright() as pw:
        b, page, errors = open_registration(pw, "blank.y4m", server)
        link(page, spare, "P906", name="Queued Person")

        page.click("#openReview")
        page.wait_for_timeout(500)
        assert page.inner_text("#rQueue").strip() != "0", "the link was not queued"
        assert "export" in page.inner_text("#syncState").lower(), \
            "with no server set the app should point at the CSV export"
        assert not errors
        b.close()
