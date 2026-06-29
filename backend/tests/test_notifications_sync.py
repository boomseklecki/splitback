"""Splitwise notification sync: HTML cleanup + the delta push (new, non-self activity pushes; backfill and
own actions don't). DB-backed; fakes the Splitwise fetch + captures push.enqueue."""
from sqlalchemy import delete, select

from app.db import async_session
from app.integrations.splitwise import importer
from app.integrations.splitwise.client import _clean_content
from app.models import Notification, NotificationMute, SplitwiseToken
from app.models.enums import NotificationSource
from app.services import sync

OWNER = "nsync-owner"


async def _purge():
    async with async_session() as s:
        await s.execute(delete(Notification).where(Notification.owner_identifier == OWNER))
        await s.execute(delete(NotificationMute).where(NotificationMute.owner_identifier == OWNER))
        await s.commit()


def _fake_fetch(notes, limit_holder=None):
    """A stand-in for sw_client.fetch_notifications returning canned, already-normalized notes."""
    def fetch(client, access_token=None, limit=None):
        if limit_holder is not None:
            limit_holder.append(limit)
        return notes
    return fetch


async def _sync(notes, *, push, retention=100, capture=None, limit_holder=None):
    orig_fetch, orig_push = importer.sw_client.fetch_notifications, importer.push_enqueue
    importer.sw_client.fetch_notifications = _fake_fetch(notes, limit_holder)
    importer.push_enqueue = (lambda owners, title, body: capture.append((owners, body))) if capture is not None \
        else (lambda *a, **k: None)
    try:
        async with async_session() as s:
            return await importer.sync_notifications(
                s, client=None, owner_identifier=OWNER, retention=retention, access_token="t", push=push)
    finally:
        importer.sw_client.fetch_notifications, importer.push_enqueue = orig_fetch, orig_push


def _note(swid, content, created="2026-06-20T12:00:00Z"):
    return {"splitwise_id": swid, "type": "expense_added", "content": content, "created_at": created}


def test_clean_content_strips_html_and_entities():
    assert _clean_content('<strong>Alex</strong> added &quot;Dinner&quot;') == 'Alex added "Dinner"'
    assert _clean_content(None) == ""


async def test_push_only_new_non_self():
    await _purge()
    try:
        # Pre-existing row → not a delta. Then sync a mix: a new partner add, a new self action, the existing one.
        async with async_session() as s:
            s.add(Notification(owner_identifier=OWNER, source=NotificationSource.splitwise,
                               splitwise_id="sw-old", content="Sam added Coffee"))
            await s.commit()
        captured: list = []
        holder: list = []
        await _sync([_note("sw-new", "Alex added Dinner"),
                     _note("sw-self", "You added Lunch"),
                     _note("sw-old", "Sam added Coffee")],
                    push=True, capture=captured, limit_holder=holder)
        assert holder == [100]                                  # fetch count tracks retention (min(100,100))
        assert len(captured) == 1 and captured[0][1] == "Alex added Dinner"   # only the new, non-self note
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"sw-old", "sw-new", "sw-self"}            # all in the feed (full log incl. self)
    finally:
        await _purge()


async def test_cold_start_lands_rows_without_pushing():
    await _purge()
    try:
        # Owner has zero prior splitwise notifications → first sync must NOT push the historical batch,
        # even with push=True; the rows still land. A later sync pushes genuinely new partner activity.
        captured: list = []
        await _sync([_note("c-1", "Alex added Dinner"), _note("c-2", "Sam added Coffee")],
                    push=True, capture=captured)
        assert captured == []                                   # cold start: no flood
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"c-1", "c-2"}
        await _sync([_note("c-1", "Alex added Dinner"), _note("c-3", "Pat added Tea")],
                    push=True, capture=captured)
        assert len(captured) == 1 and captured[0][1] == "Pat added Tea"   # only the new one, now non-cold
    finally:
        await _purge()


async def test_push_mute_splitwise_source_keeps_feed_drops_push():
    await _purge()
    try:
        async with async_session() as s:
            # Seed a prior row (so it's not a cold start) + a source:splitwise PUSH mute.
            s.add(Notification(owner_identifier=OWNER, source=NotificationSource.splitwise,
                               splitwise_id="m-old", content="Sam added Coffee"))
            s.add(NotificationMute(owner_identifier=OWNER, token="push:source:splitwise"))
            await s.commit()
        captured: list = []
        await _sync([_note("m-new", "Alex added Dinner"), _note("m-old", "Sam added Coffee")],
                    push=True, capture=captured)
        assert captured == []                                   # push muted for splitwise → no alert
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"m-old", "m-new"}                        # but the row still lands (feed intact)
    finally:
        await _purge()


async def test_fetch_count_capped_at_max_fetch():
    await _purge()
    try:
        holder: list = []
        await _sync([], push=False, retention=1000, limit_holder=holder)   # retention above the cap
        assert holder == [importer._MAX_FETCH]                  # bounded fetch (min(1000, 100))
    finally:
        await _purge()


async def test_backfill_does_not_push():
    await _purge()
    try:
        captured: list = []
        await _sync([_note("b-1", "Alex added Dinner"), _note("b-2", "Sam settled up")],
                    push=False, capture=captured)
        assert captured == []                                   # connect/backfill never pushes, even all-new
        async with async_session() as s:
            ids = set(await s.scalars(select(Notification.splitwise_id).where(
                Notification.owner_identifier == OWNER)))
        assert ids == {"b-1", "b-2"}                            # but rows still landed
    finally:
        await _purge()


async def test_resync_updates_content_without_repush():
    await _purge()
    try:
        await _sync([_note("r-1", "Alex added Dinner")], push=True)            # first time → new
        captured: list = []
        await _sync([_note("r-1", "Alex updated Dinner")], push=True, capture=captured)  # seen id → no push
        assert captured == []
        async with async_session() as s:
            row = await s.scalar(select(Notification).where(
                Notification.owner_identifier == OWNER, Notification.splitwise_id == "r-1"))
            assert row.content == "Alex updated Dinner"          # content refreshed
    finally:
        await _purge()


_TOK_A, _TOK_B = "nsync-tok-a", "nsync-tok-b"


async def test_sync_notifications_all_per_token_isolation():
    async with async_session() as s:
        await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier.in_([_TOK_A, _TOK_B])))
        s.add(SplitwiseToken(user_identifier=_TOK_A, access_token="x"))
        s.add(SplitwiseToken(user_identifier=_TOK_B, access_token="x"))
        await s.commit()
    calls: list = []

    async def fake_sync(session, client, owner, *, retention, access_token=None, push=False):
        calls.append((owner, push))
        if owner == _TOK_A:
            raise RuntimeError("boom")   # one token fails → must not abort the other

    orig_mk, orig_sync = sync.sw_client.make_client, sync.importer.sync_notifications
    sync.sw_client.make_client = lambda token: object()
    sync.importer.sync_notifications = fake_sync
    try:
        async with async_session() as s:
            count = await sync.sync_notifications_all(s)
        assert {o for o, _ in calls} == {_TOK_A, _TOK_B}        # every token attempted
        assert all(p is True for _, p in calls)                 # poll always pushes
        assert count == 1                                       # B succeeded, A raised (isolated)
    finally:
        sync.sw_client.make_client, sync.importer.sync_notifications = orig_mk, orig_sync
        async with async_session() as s:
            await s.execute(delete(SplitwiseToken).where(SplitwiseToken.user_identifier.in_([_TOK_A, _TOK_B])))
            await s.commit()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
