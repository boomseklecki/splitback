import asyncio

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.categories import CATEGORIES
from app.config import settings
from app.db import get_session
from app.integrations.anthropic import client as ai_client
from app.models import Transaction
from app.models.category_map import CategoryMap
from app.schemas.category_map import CategoryMapResponse, CategoryMapUpsert

router = APIRouter(tags=["category-map"])


@router.get("/category-map", response_model=list[CategoryMapResponse])
async def list_category_map(session: AsyncSession = Depends(get_session)) -> list[CategoryMap]:
    rows = await session.scalars(select(CategoryMap).order_by(CategoryMap.raw_category))
    return list(rows)


@router.put("/category-map", response_model=CategoryMapResponse)
async def upsert_category_map(
    body: CategoryMapUpsert, session: AsyncSession = Depends(get_session)
) -> CategoryMap:
    """Set a manual mapping. Manual rows win — they're never overwritten by AI suggestions."""
    if body.canonical_category not in CATEGORIES:
        raise HTTPException(status_code=422, detail=f"Unknown category '{body.canonical_category}'")
    row = await session.scalar(
        select(CategoryMap).where(CategoryMap.raw_category == body.raw_category)
    )
    if row is None:
        row = CategoryMap(raw_category=body.raw_category)
        session.add(row)
    row.canonical_category = body.canonical_category
    row.source = "manual"
    await session.commit()
    await session.refresh(row)
    return row


@router.post("/category-map/suggest", response_model=list[CategoryMapResponse])
async def suggest_category_map(session: AsyncSession = Depends(get_session)) -> list[CategoryMap]:
    """For every distinct transaction category not yet mapped, ask Claude to assign a canonical
    category and store the results as `source="ai"` (manual rows are left untouched)."""
    if not settings.goals_ai_categorization_enabled or not settings.anthropic_api_key:
        raise HTTPException(status_code=503, detail="AI categorization is disabled")

    existing = set(await session.scalars(select(CategoryMap.raw_category)))
    distinct = await session.scalars(
        select(Transaction.category).where(Transaction.category.is_not(None)).distinct()
    )
    unmapped = sorted({c for c in distinct if c and c not in existing})
    if not unmapped:
        return []

    suggestions = await asyncio.to_thread(ai_client.suggest_categories, unmapped)
    created: list[CategoryMap] = []
    for raw, canonical in suggestions.items():
        row = CategoryMap(raw_category=raw, canonical_category=canonical, source="ai")
        session.add(row)
        created.append(row)
    await session.commit()
    for row in created:
        await session.refresh(row)
    return created
