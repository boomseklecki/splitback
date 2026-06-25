"""In-process periodic data-sync loop.

Started unconditionally from the FastAPI lifespan; it polls a fixed tick and re-reads `sync_interval_hours`
from the server settings each cycle, so an admin turning it on/off or changing cadence takes effect within a
tick — no restart. `<= 0` = paused. Every interval it runs a full Plaid + Splitwise sync across all linked
items/tokens. Failures are logged, never raised — a bad sync must not take the API down. Cancelled cleanly on
shutdown.
"""
import asyncio
import logging
import time

from app import server_settings
from app.db import async_session
from app.services import sync

log = logging.getLogger(__name__)

_POLL_SECONDS = 60


async def run_scheduler() -> None:
    last_run = time.monotonic()  # don't fire immediately on boot
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        try:
            async with async_session() as session:
                interval = await server_settings.get(session, "sync_interval_hours")
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Data-sync scheduler: couldn't read interval; will retry.")
            continue
        if interval <= 0 or time.monotonic() - last_run < interval * 3600:
            continue
        last_run = time.monotonic()
        try:
            async with async_session() as session:
                stats = await sync.sync_all(session)
            log.info("Scheduled sync: %s Plaid items, %s Splitwise tokens.",
                     stats["plaid_items"], stats["splitwise_tokens"])
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Scheduled sync failed; will retry next interval.")
