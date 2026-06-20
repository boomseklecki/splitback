from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class CategoryMap(UUIDMixin, TimestampMixin, Base):
    """Maps a raw Plaid transaction category (as stored on `transactions.category`) to one of the
    canonical categories in `app.categories.CATEGORIES`. Lets budgets/spending analytics group raw
    Plaid labels under the app's vocabulary. `source` distinguishes on-device (Apple Intelligence)
    suggestions the app generated (overwritable) from manual user choices (sticky)."""

    __tablename__ = "category_map"

    raw_category: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    canonical_category: Mapped[str] = mapped_column(String(64), nullable=False)
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="manual")  # "ai" | "manual"
