from datetime import datetime

from sqlalchemy import Boolean, DateTime, Enum, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin
from app.models.enums import BackendType


class Group(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "groups"

    name: Mapped[str] = mapped_column(String(255), nullable=False)
    backend_type: Mapped[BackendType] = mapped_column(
        Enum(BackendType, name="backend_type"), nullable=False
    )
    # Set only when backend_type == splitwise
    splitwise_group_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Splitwise group metadata (null for self-hosted / unknown). group_type: apartment/house/trip/etc.
    group_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    cover_photo_url: Mapped[str | None] = mapped_column(String(512), nullable=True)
    # Soft-delete marker (self-hosted only); null = active
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Cosmetic visibility toggle (any backend type)
    hidden: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)

    expenses: Mapped[list["Expense"]] = relationship(  # noqa: F821
        back_populates="group", cascade="all, delete-orphan", passive_deletes=True
    )
