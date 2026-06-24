"""Brand logo proxy for the Subscriptions feature.

The iOS app points `AvatarView` at `GET /logos/{domain}`; this resolves the logo from a configurable
upstream the first time, caches the bytes in MinIO, and serves them thereafter — so merchant domains only
ever leave the *self-hosted* backend, never the app. Public (no bearer): the token-less AsyncImage loads
it directly, and a brand logo is not user data.
"""
import asyncio

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

from app.integrations import logos
from app.integrations.storage import minio_client

router = APIRouter(tags=["logos"])


@router.get("/logos/{domain}")
async def brand_logo(domain: str) -> Response:
    domain = domain.lower()
    if not logos.DOMAIN_RE.match(domain):
        raise HTTPException(status_code=404, detail="Not found")

    object_key = logos.object_key(domain)
    if await asyncio.to_thread(minio_client.object_exists, object_key):
        data = await asyncio.to_thread(minio_client.get_bytes, object_key)
        return Response(content=data, media_type="image/png")

    data = await asyncio.to_thread(logos.fetch_favicon, domain)
    if data is None:
        raise HTTPException(status_code=404, detail="No logo")
    await asyncio.to_thread(minio_client.put_object, object_key, data, "image/png")
    return Response(content=data, media_type="image/png")
