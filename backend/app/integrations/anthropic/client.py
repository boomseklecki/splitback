"""Thin Anthropic Messages-API wrapper for mapping raw Plaid category labels to our canonical
taxonomy. Uses `requests` (the backend's existing HTTP client) — blocking, so call via
`asyncio.to_thread`."""
import json

import requests

from app.categories import CATEGORIES
from app.config import settings

_API_URL = "https://api.anthropic.com/v1/messages"
_MODEL = "claude-haiku-4-5"  # cheap, sufficient for short-label classification
_TIMEOUT = 30


def _prompt(raw_labels: list[str]) -> str:
    options = ", ".join(CATEGORIES)
    labels = json.dumps(raw_labels)
    return (
        "You map bank-transaction category labels to a fixed taxonomy.\n"
        f"Allowed categories (use these EXACT strings): {options}.\n"
        f"For each raw label in this JSON array, choose the single best-fitting allowed category. "
        f"If nothing fits, use \"Other\".\n"
        f"Raw labels: {labels}\n"
        "Reply with ONLY a JSON object mapping each raw label to its chosen category, no prose."
    )


def suggest_categories(raw_labels: list[str]) -> dict[str, str]:
    """Ask Claude to map each raw label to a canonical category. Returns {raw: canonical}, dropping
    any result that isn't a known category. Blocking — call via `asyncio.to_thread`."""
    if not raw_labels:
        return {}
    resp = requests.post(
        _API_URL,
        headers={
            "x-api-key": settings.anthropic_api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json={
            "model": _MODEL,
            "max_tokens": 1024,
            "messages": [{"role": "user", "content": _prompt(raw_labels)}],
        },
        timeout=_TIMEOUT,
    )
    resp.raise_for_status()
    text = "".join(
        block.get("text", "") for block in resp.json().get("content", []) if block.get("type") == "text"
    )
    try:
        parsed = json.loads(_strip_fence(text))
    except (json.JSONDecodeError, TypeError):
        return {}
    allowed = set(CATEGORIES)
    return {
        raw: canonical
        for raw, canonical in parsed.items()
        if raw in raw_labels and canonical in allowed
    }


def _strip_fence(text: str) -> str:
    """Tolerate a ```json fenced reply."""
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[-1].rsplit("```", 1)[0]
    return stripped.strip()
