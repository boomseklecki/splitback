"""GET /server-info: identity shape + requires_auth/auth_providers reflect config (name now comes from the
server_settings `public_hostname`); GET /.well-known/apple-app-site-association: 404 until APPLE_TEAM_ID set."""
import json

from fastapi import HTTPException

from app.config import settings
from app.db import async_session
from app.routers.public import apple_app_site_association, server_info


async def test_server_info_shape():
    async with async_session() as s:
        info = await server_info(session=s)
    assert info.app == settings.app_name
    assert info.version
    assert info.name  # public_hostname (server setting) or app_name
    assert isinstance(info.auth_providers, list)


async def test_requires_auth_reflects_config():
    orig = (settings.auth_required, settings.api_tokens,
            settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key)
    try:
        # No providers, no auth_required, no tokens -> open.
        settings.apple_audience = settings.google_client_id = settings.splitwise_consumer_key = ""
        settings.auth_required, settings.api_tokens = False, {}
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is False
        # Any of auth_required / api_tokens / a configured provider flips the gate on.
        settings.auth_required = True
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is True
        settings.auth_required, settings.api_tokens = False, {"tok": "matt"}
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is True
        settings.api_tokens, settings.google_client_id = {}, "gid"
        async with async_session() as s:
            assert (await server_info(session=s)).requires_auth is True
    finally:
        (settings.auth_required, settings.api_tokens,
         settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key) = orig


async def test_auth_providers_reflect_config():
    orig = (settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key)
    try:
        settings.apple_audience = "com.splitback.app"
        settings.google_client_id = ""
        settings.splitwise_consumer_key = "key"
        async with async_session() as s:
            providers = (await server_info(session=s)).auth_providers
        assert "apple" in providers
        assert "splitwise" in providers
        assert "google" not in providers
    finally:
        settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key = orig


async def test_aasa_404_until_team_id_set():
    orig = settings.apple_team_id
    try:
        settings.apple_team_id = ""
        try:
            await apple_app_site_association()
        except HTTPException as exc:
            assert exc.status_code == 404
        else:
            raise AssertionError("expected 404")
    finally:
        settings.apple_team_id = orig


async def test_aasa_appid_when_configured():
    orig_team, orig_aud = settings.apple_team_id, settings.apple_audience
    try:
        settings.apple_team_id = "ABCDE12345"
        settings.apple_audience = "com.splitback.app"
        resp = await apple_app_site_association()
        body = json.loads(resp.body)
        appid = body["applinks"]["details"][0]["appID"]
        assert appid == "ABCDE12345.com.splitback.app"
    finally:
        settings.apple_team_id, settings.apple_audience = orig_team, orig_aud


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
