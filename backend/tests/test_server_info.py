"""GET /server-info: identity shape + requires_auth/auth_providers reflect settings."""
from app.config import settings
from app.routers.public import server_info


async def test_server_info_shape():
    info = await server_info()
    assert info.app == settings.app_name
    assert info.version
    assert info.name  # public_hostname or app_name
    assert isinstance(info.auth_providers, list)


async def test_requires_auth_reflects_settings():
    orig_req, orig_tok = settings.auth_required, settings.api_tokens
    try:
        settings.auth_required, settings.api_tokens = False, {}
        assert (await server_info()).requires_auth is False
        settings.auth_required = True
        assert (await server_info()).requires_auth is True
        settings.auth_required, settings.api_tokens = False, {"tok": "matt"}
        assert (await server_info()).requires_auth is True
    finally:
        settings.auth_required, settings.api_tokens = orig_req, orig_tok


async def test_auth_providers_reflect_config():
    orig = (settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key)
    try:
        settings.apple_audience = "com.splitback.app"
        settings.google_client_id = ""
        settings.splitwise_consumer_key = "key"
        providers = (await server_info()).auth_providers
        assert "apple" in providers
        assert "splitwise" in providers
        assert "google" not in providers
    finally:
        settings.apple_audience, settings.google_client_id, settings.splitwise_consumer_key = orig


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
