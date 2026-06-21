"""Prune old demo guest users and their data (run by cron on the DEMO backend to bound growth).

Deletes users whose identifier starts with `demo-` and that are older than --days, along with their demo
groups (cascading expenses) and personal data (accounts/transactions/goals/Plaid+Splitwise tokens). The
shared synthetic co-members (robin/sam/alex) are left as directory entries.

Usage (inside the demo api container):
    python -m app.cli.prune_demo --days 7
"""
import argparse
import asyncio
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from app.db import async_session
from app.models import Group, GroupMember, User
from app.routers.users import _purge_personal_data


async def _run(args: argparse.Namespace) -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    async with async_session() as session:
        guests = (await session.scalars(
            select(User).where(User.identifier.like("demo-%"), User.created_at < cutoff)
        )).all()
        for guest in guests:
            gids = list(await session.scalars(
                select(GroupMember.group_id).where(GroupMember.user_identifier == guest.identifier)))
            if gids:
                await session.execute(delete(Group).where(Group.id.in_(gids)))  # cascades expenses/splits
            await _purge_personal_data(session, guest.identifier)
            await session.delete(guest)
        await session.commit()
    print(f"Pruned {len(guests)} demo guests older than {args.days}d.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Prune old demo guest users + their data.")
    parser.add_argument("--days", type=int, default=7, help="delete demo users older than this many days")
    asyncio.run(_run(parser.parse_args()))


if __name__ == "__main__":
    main()
