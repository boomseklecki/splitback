"""Per-caller data scoping: lists return only the caller's rows; cross-caller writes 403; create stamps
the owner; a group's creator is auto-joined so they see it. Drives the router handlers directly with an
explicit `caller` (no HTTP/auth plumbing). Runs against the running Postgres; cleans up its own rows.
"""
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.db import async_session
from app.models import Account, Goal, Group, GroupMember
from app.routers import accounts as acct
from app.routers import goals as goals_router
from app.routers import groups as groups_router
from app.schemas.account import AccountCreate
from app.schemas.goal import GoalCreate, GoalUpdate
from app.schemas.group import GroupCreate

A = "scope-a-zzz"
B = "scope-b-zzz"


async def _cleanup(session) -> None:
    gids = list(await session.scalars(select(Group.id).where(Group.name == "Scope Group ZZZ")))
    if gids:
        await session.execute(delete(GroupMember).where(GroupMember.group_id.in_(gids)))
        await session.execute(delete(Group).where(Group.id.in_(gids)))
    await session.execute(delete(Goal).where(Goal.owner_identifier.in_([A, B])))
    await session.execute(delete(Account).where(Account.owner_identifier.in_([A, B])))
    await session.commit()


async def test_goal_scoping():
    async with async_session() as session:
        await _cleanup(session)
        try:
            goal = await goals_router.create_goal(
                GoalCreate(kind="spend", name="ZZZ", target_amount=Decimal("100")),
                caller=A, session=session)
            assert goal.owner_identifier == A

            mine = await goals_router.list_goals(caller=A, session=session)
            theirs = await goals_router.list_goals(caller=B, session=session)
            assert goal.id in [g.id for g in mine]
            assert goal.id not in [g.id for g in theirs]

            try:
                await goals_router.update_goal(goal.id, GoalUpdate(name="hijack"),
                                               caller=B, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403
        finally:
            await _cleanup(session)


async def test_account_scoping():
    async with async_session() as session:
        await _cleanup(session)
        try:
            account = await acct.create_account(AccountCreate(name="ZZZ Acct"), caller=A, session=session)
            assert account.owner_identifier == A
            mine = await acct.list_accounts(caller=A, session=session)
            theirs = await acct.list_accounts(caller=B, session=session)
            assert account.id in [x.id for x in mine] and account.id not in [x.id for x in theirs]
            try:
                await acct.delete_account(account.id, caller=B, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403
        finally:
            await _cleanup(session)


async def test_group_membership_scoping():
    async with async_session() as session:
        await _cleanup(session)
        try:
            group = await groups_router.create_group(GroupCreate(name="Scope Group ZZZ"),
                                                     caller=A, session=session)
            # Creator is auto-joined -> sees it; B is not a member -> doesn't, and is 403 on access.
            mine = await groups_router.list_groups(caller=A, session=session)
            theirs = await groups_router.list_groups(caller=B, session=session)
            assert group.id in [g.id for g in mine] and group.id not in [g.id for g in theirs]
            try:
                await groups_router.get_group(group.id, caller=B, session=session)
                assert False, "expected 403"
            except HTTPException as e:
                assert e.status_code == 403
            # Open mode (caller=None) is unscoped — sees everything.
            assert group.id in [g.id for g in await groups_router.list_groups(caller=None, session=session)]
        finally:
            await _cleanup(session)


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
