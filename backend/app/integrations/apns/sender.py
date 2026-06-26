"""APNs token-based push (HTTP/2 + ES256 provider JWT). No-op unless `settings.apns_configured`."""
import base64
import json
import logging
import time

import httpx
import jwt

from app.config import settings

log = logging.getLogger(__name__)

# Provider JWT, cached (~50 min; Apple rejects tokens older than 1h).
_token_cache: tuple[str, float] | None = None


def _provider_token() -> str:
    global _token_cache
    now = time.time()
    if _token_cache and now - _token_cache[1] < 3000:
        return _token_cache[0]
    key = base64.b64decode(settings.apns_auth_key).decode()
    token = jwt.encode(
        {"iss": settings.apns_team_id, "iat": int(now)},
        key, algorithm="ES256", headers={"kid": settings.apns_key_id})
    _token_cache = (token, now)
    return token


def _host() -> str:
    return "api.sandbox.push.apple.com" if settings.apns_env == "sandbox" else "api.push.apple.com"


async def send(client: httpx.AsyncClient, token: str, title: str, body: str) -> bool:
    """Sends one alert push; returns True if the device token is dead (caller should drop it)."""
    if not settings.apns_configured:
        return False
    payload = {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}}
    try:
        resp = await client.post(
            f"https://{_host()}/3/device/{token}",
            headers={"authorization": f"bearer {_provider_token()}",
                     "apns-topic": settings.apns_bundle_id,
                     "apns-push-type": "alert", "apns-priority": "10"},
            content=json.dumps(payload))
    except Exception:
        log.warning("apns send failed", exc_info=True)
        return False
    if resp.status_code == 410:  # Unregistered
        return True
    if resp.status_code == 400:
        try:
            return resp.json().get("reason") in ("BadDeviceToken", "DeviceTokenNotForTopic")
        except Exception:
            return False
    return False
