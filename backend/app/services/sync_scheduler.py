"""In-process periodic data-sync loop.

Started from the FastAPI lifespan when `SYNC_INTERVAL_HOURS > 0` (enable on prod). Every interval it runs a
full Plaid + Splitwise sync across all linked items/tokens. Failures are logged, never raised — a bad sync must
not take the API down. Cancelled cleanly on shutdown.
"""
import asyncio
import logging

from app.config import settings
from app.db import async_session
from app.services import sync

log = logging.getLogger(__name__)


async def run_scheduler() -> None:
    interval = settings.sync_interval_hours
    if interval <= 0:
        return
    log.info("Data-sync scheduler on: Plaid + Splitwise every %sh.", interval)
    while True:
        # Sleep first so a redeploy doesn't trigger a full sync on every restart.
        await asyncio.sleep(interval * 3600)
        try:
            async with async_session() as session:
                stats = await sync.sync_all(session)
            log.info("Scheduled sync: %s Plaid items, %s Splitwise tokens.",
                     stats["plaid_items"], stats["splitwise_tokens"])
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Scheduled sync failed; will retry next interval.")
