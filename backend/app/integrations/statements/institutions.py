"""Resolves a statement's issuing institution (OFX `<ORG>`) to a canonical name + brand domain. The
domain feeds `Account.institution_domain`, from which the logos service resolves a brand logo (e.g.
apple.com → the Apple logo).

Two layers: a small curated `_OVERRIDES` (wins — covers issuers whose `<ORG>` doesn't equal their
FIDIR name, e.g. the statement says "Apple Card" but FIDIR lists "Apple Card WC"), then an exact
normalized-name match into `institutions_data.json` (generated from Intuit's FIDIR Web Connect list
by `scripts/refresh_fidir.py`). Exact-only — a wrong logo is worse than no logo."""
import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

_DATA = Path(__file__).with_name("institutions_data.json")

# Lowercased ORG → brand domain. Hand-curated; takes precedence over the FIDIR dataset.
_OVERRIDES: dict[str, str] = {
    "apple card": "apple.com",
}


@dataclass(frozen=True)
class Institution:
    name: str
    domain: str


def _normalize(org: str) -> str:
    return " ".join(org.lower().split())


@lru_cache(maxsize=1)
def _by_name() -> dict[str, Institution]:
    """normalized FIDIR name → {name, domain}, loaded once. Missing data file → empty (overrides still work)."""
    try:
        rows = json.loads(_DATA.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    return {_normalize(r["name"]): Institution(r["name"], r["domain"]) for r in rows}


def resolve_institution(org: str | None) -> Institution | None:
    """The canonical institution for an OFX `<ORG>`, or None when unknown."""
    if not org:
        return None
    key = _normalize(org)
    if (domain := _OVERRIDES.get(key)) is not None:
        return Institution(org.strip(), domain)
    return _by_name().get(key)


def resolve_domain(org: str | None) -> str | None:
    """Backward-compatible: just the brand domain for an OFX `<ORG>`."""
    inst = resolve_institution(org)
    return inst.domain if inst else None
