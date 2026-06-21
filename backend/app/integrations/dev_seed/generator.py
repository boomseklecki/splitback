"""Pure synthetic data generator for the development backend.

Produces realistic-but-fake Splitwise-style groups/users/expenses/splits/items so a dev backend can be
populated without any real PII. It reads nothing — given a self identifier and an RNG seed it returns plain
dataclasses that `app.cli.seed_dev` persists. The self identifier is kept verbatim (so you sign into dev as
yourself); everyone else is invented. Every expense's splits balance to the cent (sum(paid)==sum(owed)==
amount), satisfying the `_validate_splits` ±0.01 rule.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import Decimal


@dataclass
class SeedUser:
    identifier: str
    display_name: str
    source: str = "manual"  # "app" for self, "manual" for invented people


@dataclass
class SeedItem:
    name: str
    quantity: Decimal
    price: Decimal
    category: str | None


@dataclass
class SeedSplit:
    user_identifier: str
    paid_share: Decimal
    owed_share: Decimal


@dataclass
class SeedExpense:
    description: str
    amount: Decimal
    currency: str
    date: date
    category: str | None
    created_by: str
    splits: list[SeedSplit]
    items: list[SeedItem] = field(default_factory=list)


@dataclass
class SeedGroup:
    name: str
    group_type: str | None
    members: list[str]
    expenses: list[SeedExpense]


@dataclass
class SeedData:
    users: list[SeedUser]
    groups: list[SeedGroup]


# Fake people (display name -> identifier is the lowercased name). Picked deterministically.
_PEOPLE = ["Robin", "Sam", "Alex", "Jordan", "Casey", "Riley"]

# Per-category merchant/description pools and plausible amount ranges (dollars).
_CATALOG: dict[str, tuple[tuple[int, int], list[str]]] = {
    "Groceries": ((25, 140), ["Corner Market", "Greenleaf Grocery", "Daily Foods", "Market Basket"]),
    "Dining": ((18, 95), ["Trattoria Nove", "Noodle House", "The Local Tap", "Sushi Corner"]),
    "Utilities": ((45, 180), ["City Power", "Metro Water", "Fiber Internet", "Gas Co."]),
    "Rent": ((1400, 2200), ["Monthly Rent"]),
    "Household": ((12, 80), ["Hardware Depot", "Cleaning Supplies", "HomeGoods"]),
    "Entertainment": ((15, 70), ["Cinema 8", "Bowling Alley", "Game Night"]),
    "Travel": ((80, 420), ["Coastal Inn", "Air Fare", "Rental Car"]),
    "Fuel": ((28, 65), ["QuickFill", "Shell Station", "Gas Stop"]),
    "Transport": ((8, 45), ["Rideshare", "Metro Pass", "Taxi"]),
}

_GROCERY_ITEMS = ["Milk", "Eggs", "Bread", "Coffee", "Produce", "Chicken", "Pasta", "Cheese", "Snacks"]


def _money(rng: random.Random, lo: int, hi: int) -> Decimal:
    cents = rng.randint(lo * 100, hi * 100)
    return (Decimal(cents) / 100).quantize(Decimal("0.01"))


def _equal_owed(amount: Decimal, members: list[str]) -> dict[str, Decimal]:
    """Split `amount` into per-member owed shares, distributing remainder cents to the first members so the
    shares sum exactly to `amount`."""
    cents = int((amount * 100).to_integral_value())
    base, rem = divmod(cents, len(members))
    return {
        m: (Decimal(base + (1 if i < rem else 0)) / 100)
        for i, m in enumerate(members)
    }


def _splits(amount: Decimal, members: list[str], payer: str) -> list[SeedSplit]:
    owed = _equal_owed(amount, members)
    return [
        SeedSplit(user_identifier=m,
                  paid_share=amount if m == payer else Decimal("0.00"),
                  owed_share=owed[m])
        for m in members
    ]


def _grocery_items(rng: random.Random, total: Decimal) -> tuple[Decimal, list[SeedItem]]:
    """A handful of items whose prices sum exactly to a fresh total (returned alongside)."""
    count = rng.randint(3, 6)
    names = rng.sample(_GROCERY_ITEMS, count)
    items = [SeedItem(name=n, quantity=Decimal("1"),
                      price=_money(rng, 3, 18),
                      category="Groceries") for n in names]
    total = sum((i.price for i in items), Decimal("0.00"))
    return total, items


def _expense(rng: random.Random, category: str, members: list[str], day: date,
             currency: str, itemized: bool) -> SeedExpense:
    (lo, hi), merchants = _CATALOG[category]
    payer = rng.choice(members)
    items: list[SeedItem] = []
    if itemized and category == "Groceries":
        amount, items = _grocery_items(rng, Decimal("0"))
        description = rng.choice(merchants)
    else:
        amount = _money(rng, lo, hi)
        description = rng.choice(merchants)
    return SeedExpense(
        description=description, amount=amount, currency=currency, date=day,
        category=category, created_by=payer,
        splits=_splits(amount, members, payer), items=items,
    )


def generate(self_identifier: str = "matt", *, seed: int = 1234,
             today: date | None = None, currency: str = "USD") -> SeedData:
    """Deterministic for a given (self_identifier, seed, today)."""
    rng = random.Random(seed)
    today = today or date.today()

    you = SeedUser(identifier=self_identifier,
                   display_name=self_identifier.capitalize(), source="app")
    roommate = SeedUser(identifier=_PEOPLE[0].lower(), display_name=_PEOPLE[0])
    friends = [SeedUser(identifier=p.lower(), display_name=p) for p in _PEOPLE[1:3]]
    users = [you, roommate, *friends]

    def days_ago(n: int) -> date:
        return today - timedelta(days=n)

    # Apartment: you + one roommate, ~16 expenses over ~4 months (monthly rent/utilities + frequent spend).
    apt_members = [you.identifier, roommate.identifier]
    apt_expenses: list[SeedExpense] = []
    for month in range(4):
        base = month * 30
        apt_expenses.append(_expense(rng, "Rent", apt_members, days_ago(base + 1), currency, False))
        apt_expenses.append(_expense(rng, "Utilities", apt_members, days_ago(base + 3), currency, False))
        for _ in range(2):
            apt_expenses.append(_expense(rng, "Groceries", apt_members,
                                         days_ago(base + rng.randint(5, 25)), currency, True))
        apt_expenses.append(_expense(rng, rng.choice(["Dining", "Household", "Entertainment"]),
                                     apt_members, days_ago(base + rng.randint(5, 25)), currency, False))

    # Trip: you + two friends, a cluster of expenses on one recent week.
    trip_members = [you.identifier] + [f.identifier for f in friends]
    trip_start = 18
    trip_expenses = [
        _expense(rng, "Travel", trip_members, days_ago(trip_start), currency, False),
        _expense(rng, "Travel", trip_members, days_ago(trip_start), currency, False),
        _expense(rng, "Dining", trip_members, days_ago(trip_start - 1), currency, False),
        _expense(rng, "Fuel", trip_members, days_ago(trip_start - 1), currency, False),
        _expense(rng, "Entertainment", trip_members, days_ago(trip_start - 2), currency, False),
        _expense(rng, "Dining", trip_members, days_ago(trip_start - 2), currency, False),
        _expense(rng, "Transport", trip_members, days_ago(trip_start - 3), currency, False),
    ]

    groups = [
        SeedGroup(name="Apartment", group_type="apartment", members=apt_members, expenses=apt_expenses),
        SeedGroup(name="Weekend Trip", group_type="trip", members=trip_members, expenses=trip_expenses),
    ]
    return SeedData(users=users, groups=groups)
