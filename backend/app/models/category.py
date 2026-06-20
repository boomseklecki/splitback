from sqlalchemy import Boolean, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Category(UUIDMixin, TimestampMixin, Base):
    """The editable canonical category taxonomy. Seeded with the built-ins from `app.categories`
    (`builtin=True`); users can add/rename/delete any. `icon` is an optional SF Symbol name chosen in
    the app — null falls back to the app's keyword icon for the name. The structural categories
    (Transfer/Income/Settle-up) are matched by name in analytics regardless of membership here, so
    spend-exclusion never breaks if one is removed."""

    __tablename__ = "categories"

    name: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    builtin: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    position: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    icon: Mapped[str | None] = mapped_column(String(64), nullable=True)
