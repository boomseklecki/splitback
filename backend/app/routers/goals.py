from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import get_session
from app.models.goal import Goal
from app.schemas.goal import GoalCreate, GoalResponse, GoalUpdate

router = APIRouter(tags=["goals"])


@router.post("/goals", response_model=GoalResponse, status_code=201)
async def create_goal(body: GoalCreate, session: AsyncSession = Depends(get_session)) -> Goal:
    goal = Goal(
        kind=body.kind,
        name=body.name,
        category=body.category,
        account_id=body.account_id,
        target_amount=body.target_amount,
        save_target_type=body.save_target_type,
        starting_balance=body.starting_balance,
        starting_date=body.starting_date,
        period=body.period,
        currency=body.currency or settings.default_currency,
    )
    session.add(goal)
    await session.commit()
    await session.refresh(goal)
    return goal


@router.get("/goals", response_model=list[GoalResponse])
async def list_goals(
    include_archived: bool = False, session: AsyncSession = Depends(get_session)
) -> list[Goal]:
    stmt = select(Goal)
    if not include_archived:
        stmt = stmt.where(Goal.archived_at.is_(None))
    rows = await session.scalars(stmt.order_by(Goal.created_at.desc()))
    return list(rows)


async def _get_or_404(session: AsyncSession, goal_id: UUID) -> Goal:
    goal = await session.get(Goal, goal_id)
    if goal is None:
        raise HTTPException(status_code=404, detail="Goal not found")
    return goal


@router.patch("/goals/{goal_id}", response_model=GoalResponse)
async def update_goal(
    goal_id: UUID, body: GoalUpdate, session: AsyncSession = Depends(get_session)
) -> Goal:
    goal = await _get_or_404(session, goal_id)
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(goal, field, value)
    await session.commit()
    await session.refresh(goal)
    return goal


@router.delete("/goals/{goal_id}", status_code=204)
async def delete_goal(goal_id: UUID, session: AsyncSession = Depends(get_session)) -> None:
    goal = await _get_or_404(session, goal_id)
    goal.archived_at = datetime.now(timezone.utc)
    await session.commit()
