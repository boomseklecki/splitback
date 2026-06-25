"""In-process scheduled-backup loop.

Started unconditionally from the FastAPI lifespan; it polls a fixed tick and re-reads `backup_interval_hours`
from the server settings each cycle, so an admin turning it on/off or changing cadence takes effect within a
tick — no restart. `<= 0` = paused. Every interval it creates a `scheduled` backup and prunes per the
retention policy (also read from server settings). Failures are logged, never raised. Cancelled cleanly on
shutdown.
"""
import asyncio
import logging
import time

from app import server_settings
from app.db import async_session
from app.services import backups

log = logging.getLogger(__name__)

_POLL_SECONDS = 60


async def run_scheduler() -> None:
    last_run = time.monotonic()  # don't fire immediately on boot
    while True:
        await asyncio.sleep(_POLL_SECONDS)
        try:
            async with async_session() as session:
                interval = await server_settings.get(session, "backup_interval_hours")
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Backup scheduler: couldn't read interval; will retry.")
            continue
        if interval <= 0 or time.monotonic() - last_run < interval * 3600:
            continue
        last_run = time.monotonic()
        try:
            info = await backups.create(label="scheduled", kind=backups.KIND_SCHEDULED)
            deleted = await backups.prune()
            log.info("Scheduled backup %s created; pruned %d.", info.name, len(deleted))
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Scheduled backup failed; will retry next interval.")
