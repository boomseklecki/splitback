from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class SplitwiseToken(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "splitwise_tokens"

    # Local identifier the token belongs to (e.g. "matt")
    user_identifier: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    access_token: Mapped[str] = mapped_column(String(512), nullable=False)
    token_type: Mapped[str] = mapped_column(String(32), nullable=False, default="bearer")
    scope: Mapped[str | None] = mapped_column(String(256), nullable=True)
