from datetime import datetime

from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class SplitwiseOAuthState(Base):
    __tablename__ = "splitwise_oauth_states"

    # Random opaque value echoed back by Splitwise on the callback
    state: Mapped[str] = mapped_column(String(128), primary_key=True)
    # PKCE verifier held between /login and /callback; deleted on use
    code_verifier: Mapped[str] = mapped_column(String(128), nullable=False)
    # Local identifier initiating the flow
    user_identifier: Mapped[str] = mapped_column(String(128), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
