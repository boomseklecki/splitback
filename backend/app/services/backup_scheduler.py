"""In-process scheduled-backup loop.

Started from the FastAPI lifespan when `BACKUP_INTERVAL_HOURS > 0` (enable on prod only). Every interval it
creates a `scheduled` backup and prunes per the retention policy. Failures are logged, never raised — a bad
backup must not take the API down. Cancelled cleanly on shutdown.
"""
import asyncio
import logging

from app.config import settings
from app.services import backups

log = logging.getLogger(__name__)


async def run_scheduler() -> None:
    interval = settings.backup_interval_hours
    if interval <= 0:
        return
    log.info("Backup scheduler on: every %sh (retain %sd, keep >=%s).",
             interval, settings.backups_retention_days, settings.backups_retention_min_keep)
    while True:
        # Sleep first so a redeploy doesn't trigger a backup on every restart.
        await asyncio.sleep(interval * 3600)
        try:
            info = await backups.create(label="scheduled", kind=backups.KIND_SCHEDULED)
            deleted = await backups.prune()
            log.info("Scheduled backup %s created; pruned %d.", info.name, len(deleted))
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Scheduled backup failed; will retry next interval.")
