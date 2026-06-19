from sqlalchemy import Enum, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import UserSource


class User(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "users"

    # Join key matching splits.user_identifier (directory, no hard FK on splits).
    identifier: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)
    source: Mapped[UserSource] = mapped_column(Enum(UserSource, name="user_source"), nullable=False)
    splitwise_user_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    email: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Splitwise registration_status: "confirmed" | "invited" | "dummy" (null for non-Splitwise users).
    registration_status: Mapped[str | None] = mapped_column(String(32), nullable=True)
    # Provider subject ids captured at sign-in (find-or-create/link key); each unique when set.
    apple_sub: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True)
    google_sub: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
