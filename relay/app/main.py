import logging
from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from app import apns, db, ratelimit
from app.config import settings

log = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init()
    yield


app = FastAPI(title="SplitBack Push Relay", lifespan=lifespan)


def require_key(authorization: str | None = Header(default=None)) -> None:
    key = authorization.removeprefix("Bearer ").strip() if authorization else ""
    if not key or not db.valid_key(key):
        raise HTTPException(status_code=401, detail="Invalid API key")
    ratelimit.check(f"push:{db.hash_key(key)}", settings.push_max_per_minute, 60)


def require_admin(authorization: str | None = Header(default=None)) -> None:
    token = authorization.removeprefix("Bearer ").strip() if authorization else ""
    if not settings.admin_token or token != settings.admin_token:
        raise HTTPException(status_code=403, detail="Admin only")


class EncMessage(BaseModel):
    token: str
    epk: str
    box: str


class PushRequest(BaseModel):
    # Plaintext form (back-compat): relay sees the content.
    tokens: list[str] = []
    title: str = "SplitBack"
    body: str = ""
    # E2E form: per-device ciphertext + a generic fallback alert. Relay stays blind.
    messages: list[EncMessage] = []
    fallback_title: str = "SplitBack"
    fallback_body: str = "New activity"


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "apns_configured": settings.apns_configured}


@app.post("/push")
async def push(body: PushRequest, _: None = Depends(require_key)) -> dict:
    """Forwards alerts to APNs (encrypted `messages` and/or plaintext `tokens`); returns dead tokens to
    prune. With `RELAY_REQUIRE_E2EE`, plaintext pushes are refused so the relay only ever sees ciphertext."""
    if not settings.apns_configured:
        raise HTTPException(status_code=503, detail="Relay APNs is not configured")
    if settings.require_e2ee and body.tokens:
        raise HTTPException(status_code=400, detail="This relay accepts only E2E-encrypted pushes")
    dead: list[str] = []
    async with httpx.AsyncClient(http2=True, timeout=10) as client:
        for m in body.messages:
            if await apns.send_encrypted(client, m.token, body.fallback_title, body.fallback_body,
                                         m.epk, m.box):
                dead.append(m.token)
        for token in body.tokens:
            if await apns.send(client, token, body.title, body.body):
                dead.append(token)
    return {"dead": dead}


_FORM = """<!doctype html><meta charset=utf-8><title>SplitBack Push Relay</title>
<body style="font-family:system-ui;max-width:34rem;margin:3rem auto;padding:0 1rem;line-height:1.5">
<h1>SplitBack push relay</h1>
<p>Register your self-hosted SplitBack instance to send push through the official app.
The key is shown once — copy it.</p>
<form method=post action=/register>
<p><input name=email type=email required placeholder="you@example.com" style="width:100%;padding:.5rem"></p>
<p><input name=instance placeholder="instance name (optional)" style="width:100%;padding:.5rem"></p>
<p><button type=submit style="padding:.5rem 1rem">Get an API key</button></p>
</form></body>"""


def _page(inner: str) -> HTMLResponse:
    return HTMLResponse("<!doctype html><meta charset=utf-8><body style='font-family:system-ui;"
                        f"max-width:34rem;margin:3rem auto;padding:0 1rem;line-height:1.5'>{inner}</body>")


@app.get("/", response_class=HTMLResponse)
def form() -> str:
    return _FORM


@app.post("/register")
async def register(request: Request, email: str = Form(...), instance: str = Form("")) -> HTMLResponse:
    ratelimit.check(f"register:{ratelimit.client_ip(request)}", settings.register_max_per_hour, 3600)
    key = db.create_key(email, instance or None)
    if settings.relay_auto_issue:
        return _page(
            "<p><strong>Your API key (copy it now — shown once):</strong></p>"
            f"<pre style='padding:1rem;background:#f4f4f4;overflow:auto'>{key}</pre>"
            "<p>Set it on your SplitBack backend as <code>PUSH_RELAY_API_KEY</code> "
            "(with <code>PUSH_RELAY_URL</code>).</p>")
    return _page("<p>Request received — your key will activate once it's approved.</p>")


@app.post("/admin/keys/{key_id}/approve")
def approve(key_id: int, _: None = Depends(require_admin)) -> dict:
    if not db.set_flags(key_id, approved=1, active=1):
        raise HTTPException(status_code=404, detail="Key not found")
    return {"ok": True}


@app.post("/admin/keys/{key_id}/revoke")
def revoke(key_id: int, _: None = Depends(require_admin)) -> dict:
    if not db.set_flags(key_id, active=0):
        raise HTTPException(status_code=404, detail="Key not found")
    return {"ok": True}
