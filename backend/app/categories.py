"""Canonical category taxonomy.

The category picker, import mapping, and AI categorization now live on-device; this list remains as the
reference vocabulary the dev seed validates against (see `tests/test_dev_seed.py`).
"""

CATEGORIES: list[str] = [
    "Groceries",
    "Dining",
    "Transport",
    "Fuel",
    "Utilities",
    "Rent",
    "Mortgage",
    "Entertainment",
    "Travel",
    "Health",
    "Insurance",
    "Shopping",
    "Household",
    "Subscriptions",
    "Education",
    "Gifts",
    "Personal Care",
    "Pets",
    "Fees",
    "Income",
    "Transfer",
    "Settle-up",
    "Other",
]
