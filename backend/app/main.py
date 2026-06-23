import asyncio
import contextlib
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI

from app.auth import require_auth
from app.config import settings
from app.integrations.storage import minio_client
from app.routers import (
    accounts,
    auth,
    backups,
    balances,
    categories,
    category_map,
    expenses,
    goals,
    groups,
    health,
    logos,
    plaid,
    public,
    receipts,
    splitwise,
    splitwise_auth,
    users,
)
from app.services.backup_scheduler import run_scheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    # MinIO may start a moment after the API; retry the bucket check briefly.
    for _ in range(10):
        try:
            await asyncio.to_thread(minio_client.ensure_bucket)
            break
        except Exception:
            await asyncio.sleep(1)
    # Scheduled backups (no-op unless BACKUP_INTERVAL_HOURS > 0).
    scheduler = asyncio.create_task(run_scheduler())
    try:
        yield
    finally:
        scheduler.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await scheduler


app = FastAPI(title=settings.app_name, version="0.1.0", lifespan=lifespan)

# Open: healthchecks, sign-in, and the Splitwise OAuth browser redirect can't carry a bearer.
app.include_router(health.router)
app.include_router(public.router)
app.include_router(auth.router)
app.include_router(splitwise_auth.router)
app.include_router(logos.router)  # public: token-less AsyncImage loads brand logos; not user data

# Guarded by bearer auth when API_TOKENS is configured (pass-through otherwise).
_protected = [Depends(require_auth)]
app.include_router(groups.router, dependencies=_protected)
app.include_router(expenses.router, dependencies=_protected)
app.include_router(receipts.router, dependencies=_protected)
app.include_router(plaid.router, dependencies=_protected)
app.include_router(accounts.router, dependencies=_protected)
app.include_router(users.router, dependencies=_protected)
app.include_router(balances.router, dependencies=_protected)
app.include_router(splitwise.router, dependencies=_protected)
app.include_router(categories.router, dependencies=_protected)
app.include_router(category_map.router, dependencies=_protected)
app.include_router(goals.router, dependencies=_protected)
app.include_router(backups.router)  # each route self-gates with require_admin


@app.get("/")
async def root() -> dict[str, str]:
    return {"app": settings.app_name, "status": "running"}
