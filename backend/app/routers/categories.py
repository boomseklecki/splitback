from fastapi import APIRouter

from app.categories import CATEGORIES

router = APIRouter(tags=["categories"])


@router.get("/categories", response_model=list[str])
async def list_categories() -> list[str]:
    return CATEGORIES
