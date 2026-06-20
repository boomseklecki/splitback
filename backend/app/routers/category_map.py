from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models.category import Category
from app.models.category_map import CategoryMap
from app.schemas.category_map import CategoryMapResponse, CategoryMapUpsert

router = APIRouter(tags=["category-map"])

_SOURCES = {"manual", "ondevice"}


@router.get("/category-map", response_model=list[CategoryMapResponse])
async def list_category_map(session: AsyncSession = Depends(get_session)) -> list[CategoryMap]:
    rows = await session.scalars(select(CategoryMap).order_by(CategoryMap.raw_category))
    return list(rows)


@router.put("/category-map", response_model=CategoryMapResponse)
async def upsert_category_map(
    body: CategoryMapUpsert, session: AsyncSession = Depends(get_session)
) -> CategoryMap:
    """Store a raw→canonical mapping. `source` distinguishes a user's manual pick from an on-device
    (Apple Intelligence) suggestion the app generated; the app decides whether to overwrite a row
    (it leaves manual picks alone and only refreshes its own suggestions)."""
    known = await session.scalar(
        select(Category.id).where(Category.name == body.canonical_category)
    )
    if known is None:
        raise HTTPException(status_code=422, detail=f"Unknown category '{body.canonical_category}'")
    if body.source not in _SOURCES:
        raise HTTPException(status_code=422, detail=f"Unknown source '{body.source}'")
    row = await session.scalar(
        select(CategoryMap).where(CategoryMap.raw_category == body.raw_category)
    )
    if row is None:
        row = CategoryMap(raw_category=body.raw_category)
        session.add(row)
    row.canonical_category = body.canonical_category
    row.source = body.source
    await session.commit()
    await session.refresh(row)
    return row
