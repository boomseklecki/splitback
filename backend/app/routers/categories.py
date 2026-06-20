from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models.category import Category
from app.schemas.category import CategoryCreate, CategoryResponse, CategoryUpdate

router = APIRouter(tags=["categories"])


@router.get("/categories", response_model=list[CategoryResponse])
async def list_categories(session: AsyncSession = Depends(get_session)) -> list[Category]:
    rows = await session.scalars(
        select(Category).order_by(Category.builtin.desc(), Category.position, Category.name)
    )
    return list(rows)


async def _get_or_404(session: AsyncSession, category_id: UUID) -> Category:
    category = await session.get(Category, category_id)
    if category is None:
        raise HTTPException(status_code=404, detail="Category not found")
    return category


async def _ensure_unique(session: AsyncSession, name: str, exclude: UUID | None = None) -> None:
    stmt = select(Category).where(func.lower(Category.name) == name.lower())
    if exclude is not None:
        stmt = stmt.where(Category.id != exclude)
    if await session.scalar(stmt) is not None:
        raise HTTPException(status_code=409, detail=f"Category '{name}' already exists")


@router.post("/categories", response_model=CategoryResponse, status_code=201)
async def create_category(
    body: CategoryCreate, session: AsyncSession = Depends(get_session)
) -> Category:
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Name is required")
    await _ensure_unique(session, name)
    max_position = await session.scalar(select(func.max(Category.position))) or 0
    category = Category(name=name, builtin=False, position=max_position + 1, icon=body.icon)
    session.add(category)
    await session.commit()
    await session.refresh(category)
    return category


@router.patch("/categories/{category_id}", response_model=CategoryResponse)
async def update_category(
    category_id: UUID, body: CategoryUpdate, session: AsyncSession = Depends(get_session)
) -> Category:
    """Rename and/or set the icon. Full control — built-ins are editable too; renaming a built-in can
    orphan the deterministic Plaid/Splitwise maps that output its name (the app warns on this)."""
    category = await _get_or_404(session, category_id)
    data = body.model_dump(exclude_unset=True)
    if "name" in data:
        name = (data["name"] or "").strip()
        if not name:
            raise HTTPException(status_code=422, detail="Name is required")
        await _ensure_unique(session, name, exclude=category_id)
        category.name = name
    if "icon" in data:
        category.icon = data["icon"]
    await session.commit()
    await session.refresh(category)
    return category


@router.delete("/categories/{category_id}", status_code=204)
async def delete_category(
    category_id: UUID, session: AsyncSession = Depends(get_session)
) -> None:
    category = await _get_or_404(session, category_id)
    await session.delete(category)
    await session.commit()
