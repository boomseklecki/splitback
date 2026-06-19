import uuid

from sqlalchemy import ForeignKey, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.base import TimestampMixin, UUIDMixin


class Receipt(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "receipts"

    expense_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("expenses.id", ondelete="CASCADE"), nullable=False
    )
    # MinIO object reference; the app fetches bytes via the API (GET /receipts/{id}/content)
    bucket: Mapped[str] = mapped_column(String(128), nullable=False)
    object_key: Mapped[str] = mapped_column(String(512), nullable=False)
    content_type: Mapped[str | None] = mapped_column(String(128), nullable=True)

    expense: Mapped["Expense"] = relationship(back_populates="receipts")  # noqa: F821
