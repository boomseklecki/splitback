"""Brand logo proxy for the Subscriptions feature.

The iOS app points `AvatarView` at `GET /logos/{domain}`; this resolves the logo from a configurable
upstream the first time, caches the bytes in MinIO, and serves them thereafter — so merchant domains only
ever leave the *self-hosted* backend, never the app. Public (no bearer): the token-less AsyncImage loads
it directly, and a brand logo is not user data.
"""
import asyncio
import re

import requests
from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

from app.config import settings
from app.integrations.storage import minio_client

router = APIRouter(tags=["logos"])

# Conservative domain shape (lowercased host, e.g. "netflix.com"). Keeps the cache key + upstream URL safe.
_DOMAIN_RE = re.compile(r"^[a-z0-9.-]{3,255}$")


def _fetch_upstream(url: str) -> bytes | None:
    """Blocking upstream fetch; returns image bytes or None. Wrap in to_thread."""
    try:
        resp = requests.get(url, timeout=8, allow_redirects=True)
    except requests.RequestException:
        return None
    if resp.status_code != 200 or not resp.content:
        return None
    content_type = resp.headers.get("Content-Type", "")
    if not content_type.startswith("image/"):
        return None
    return resp.content


@router.get("/logos/{domain}")
async def brand_logo(domain: str) -> Response:
    domain = domain.lower()
    if not _DOMAIN_RE.match(domain):
        raise HTTPException(status_code=404, detail="Not found")

    object_key = f"logos/{domain}.img"
    if await asyncio.to_thread(minio_client.object_exists, object_key):
        data = await asyncio.to_thread(minio_client.get_bytes, object_key)
        return Response(content=data, media_type="image/png")

    url = settings.logo_upstream_template.format(domain=domain)
    data = await asyncio.to_thread(_fetch_upstream, url)
    if data is None:
        raise HTTPException(status_code=404, detail="No logo")
    await asyncio.to_thread(minio_client.put_object, object_key, data, "image/png")
    return Response(content=data, media_type="image/png")
