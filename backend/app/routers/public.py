"""Unguarded public endpoints used during onboarding (before the app has adopted this backend)."""
from fastapi import APIRouter

from app.config import settings
from app.schemas.public import ServerInfo

router = APIRouter(tags=["public"])

_VERSION = "0.1.0"


@router.get("/server-info", response_model=ServerInfo)
async def server_info() -> ServerInfo:
    """Identity the iOS app pings to verify a URL is really a SplitBack backend before adopting it
    (the join-link confirm screen). Reveals nothing sensitive."""
    providers: list[str] = []
    if settings.apple_audience:
        providers.append("apple")
    if settings.google_client_id:
        providers.append("google")
    if settings.splitwise_consumer_key:
        providers.append("splitwise")
    return ServerInfo(
        app=settings.app_name,
        version=_VERSION,
        name=settings.public_hostname or settings.app_name,
        requires_auth=bool(settings.auth_required or settings.api_tokens),
        auth_providers=providers,
    )
