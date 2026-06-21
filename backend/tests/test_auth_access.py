"""Sign-in allowlist (email-only) + closed registration. Toggles settings in-process and restores them;
cleans up its own users. Runs against the running Postgres.
"""
from fastapi import HTTPException
from sqlalchemy import delete

from app.auth.access import is_allowed
from app.auth.identity import resolve_user
from app.config import settings
from app.db import async_session
from app.models import User
from app.models.enums import UserSource

ALLOWED = "allow-access-zzz@example.com"
DENIED = "deny-access-zzz@example.com"
NEWBIE = "newbie-access-zzz@example.com"
SUBS = ["acc-sub-zzz-1", "acc-sub-zzz-2", "acc-sub-zzz-3"]


async def _purge():
    async with async_session() as session:
        await session.execute(delete(User).where(User.email.in_([ALLOWED, DENIED, NEWBIE])))
        await session.execute(delete(User).where(User.google_sub.in_(SUBS)))
        await session.commit()


def test_is_allowed_email_only():
    saved = settings.auth_allowed_users
    try:
        settings.auth_allowed_users = []
        assert is_allowed(email="anyone@x.com", user=None)        # empty list = allow all
        settings.auth_allowed_users = [ALLOWED]
        assert is_allowed(email=ALLOWED.upper(), user=None)       # case-insensitive
        assert not is_allowed(email=DENIED, user=None)
        # passes via the user's STORED email even when the token omits it (Apple)
        assert is_allowed(email=None, user=User(identifier="x", display_name="X",
                                                source=UserSource.app, email=ALLOWED))
    finally:
        settings.auth_allowed_users = saved


async def test_allowlist_and_closed_registration_in_resolve():
    saved_list, saved_closed = settings.auth_allowed_users, settings.closed_registration
    await _purge()
    try:
        # Allowlisted email -> creates fine.
        settings.auth_allowed_users = [ALLOWED]
        async with async_session() as s:
            u = await resolve_user(s, provider="google", sub=SUBS[0], email=ALLOWED,
                                   name="Allowed", avatar=None)
            assert u.email == ALLOWED

        # Off-list email -> 403, no user created.
        async with async_session() as s:
            try:
                await resolve_user(s, provider="google", sub=SUBS[1], email=DENIED,
                                   name="Denied", avatar=None)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403

        # Closed registration: a brand-new identity is refused, but an existing user still signs in.
        settings.auth_allowed_users = []
        settings.closed_registration = True
        async with async_session() as s:
            try:
                await resolve_user(s, provider="google", sub=SUBS[2], email=NEWBIE,
                                   name="New", avatar=None)
                assert False, "expected 403 (registration closed)"
            except HTTPException as e:
                assert e.status_code == 403
        async with async_session() as s:
            again = await resolve_user(s, provider="google", sub=SUBS[0], email=ALLOWED,
                                       name=None, avatar=None)
            assert again.email == ALLOWED
    finally:
        settings.auth_allowed_users, settings.closed_registration = saved_list, saved_closed
        await _purge()


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
