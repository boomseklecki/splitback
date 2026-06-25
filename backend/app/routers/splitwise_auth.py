import asyncio

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import RedirectResponse
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import tokens
from app.auth.identity import resolve_user
from app.db import get_session
from app.integrations.splitwise.client import get_current_user, make_client
from app.integrations.splitwise.oauth import build_authorize_url, exchange_code
from app.integrations.splitwise.pkce import (
    code_challenge_s256,
    generate_code_verifier,
    generate_state,
)
from app.models import SplitwiseOAuthState, SplitwiseToken

router = APIRouter(prefix="/auth/splitwise", tags=["splitwise-auth"])


@router.get("/login")
async def login(
    user: str = "matt", invite: str | None = None, session: AsyncSession = Depends(get_session)
):
    verifier = generate_code_verifier()
    state = generate_state()
    session.add(
        SplitwiseOAuthState(state=state, code_verifier=verifier, user_identifier=user, invite=invite)
    )
    await session.commit()
    return RedirectResponse(build_authorize_url(state, code_challenge_s256(verifier)))


@router.get("/callback")
async def callback(code: str, state: str, session: AsyncSession = Depends(get_session)):
    pending = await session.get(SplitwiseOAuthState, state)
    if pending is None:
        raise HTTPException(status_code=400, detail="Unknown or expired OAuth state")

    user_identifier = pending.user_identifier
    code_verifier = pending.code_verifier
    invite = pending.invite
    token_data = await asyncio.to_thread(exchange_code, code, code_verifier)
    access_token = token_data.get("access_token")
    if not access_token:
        raise HTTPException(status_code=502, detail="Splitwise returned no access token")

    values = {
        "user_identifier": user_identifier,
        "access_token": access_token,
        "token_type": token_data.get("token_type", "bearer"),
        "scope": token_data.get("scope"),
    }
    await session.execute(
        pg_insert(SplitwiseToken)
        .values(**values)
        .on_conflict_do_update(
            index_elements=[SplitwiseToken.user_identifier],
            set_={k: values[k] for k in ("access_token", "token_type", "scope")},
        )
    )
    await session.delete(pending)
    await session.commit()

    # Resolve the Splitwise identity into a User and mint our own session JWT, then hand it back
    # to the iOS app via the custom scheme it catches in ASWebAuthenticationSession.
    client = make_client(access_token)
    sw_user = await asyncio.to_thread(get_current_user, client)
    full_name = f"{sw_user['first_name']} {sw_user['last_name']}".strip()
    user = await resolve_user(
        session,
        provider="splitwise",
        sub=sw_user["splitwise_id"],
        email=sw_user.get("email"),
        name=full_name or None,
        avatar=sw_user.get("picture"),
        invite_code=invite,
    )
    return RedirectResponse(f"splitback://auth?token={tokens.issue(user)}")
