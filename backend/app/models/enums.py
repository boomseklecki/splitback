import enum


class BackendType(str, enum.Enum):
    self_hosted = "self_hosted"
    splitwise = "splitwise"


class TransactionSource(str, enum.Enum):
    plaid = "plaid"
    manual = "manual"


class UserSource(str, enum.Enum):
    app = "app"
    manual = "manual"
    splitwise = "splitwise"
