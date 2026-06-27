"""Tolerant OFX statement parser (no third-party dep). OFX is finicky SGML (1.x, leaf tags often unclosed) or
XML (2.x); rather than strict-parse we scan tags. Extracts the account meta + each `<STMTTRN>`. The amount is
flipped to SplitBack's convention (positive = outflow) — OFX `<TRNAMT>` is negative for purchases — matching
the Plaid mapper (which stores positive for money leaving the account)."""
import re
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation

_STMTTRN = re.compile(r"<STMTTRN>(.*?)</STMTTRN>", re.I | re.S)
_LEDGERBAL = re.compile(r"<LEDGERBAL>(.*?)</LEDGERBAL>", re.I | re.S)
_AVAILBAL = re.compile(r"<AVAILBAL>(.*?)</AVAILBAL>", re.I | re.S)


@dataclass
class ParsedTxn:
    fitid: str
    date: date
    amount: Decimal  # SplitBack convention: positive = outflow (spend), negative = inflow (payment/credit)
    description: str


@dataclass
class ParsedStatement:
    org: str | None
    acctid: str | None
    currency: str
    ledger_balance: Decimal | None = None      # OFX <LEDGERBAL><BALAMT> (negative-when-owed; caller flips)
    available_balance: Decimal | None = None   # OFX <AVAILBAL><BALAMT> (available credit; positive)
    ledger_as_of: date | None = None           # <LEDGERBAL><DTASOF> — the date the balances reflect
    transactions: list[ParsedTxn] = field(default_factory=list)


def _leaf(tag: str, text: str) -> str | None:
    """The value of a leaf element `<TAG>value` — up to the next tag or end of line. Works for SGML (unclosed
    leaves) and XML (`<TAG>value</TAG>`) alike, since we stop at the next `<`."""
    m = re.search(rf"<{tag}>([^<\r\n]*)", text, re.I)
    return m.group(1).strip() if m else None


def _parse_date(value: str | None) -> date | None:
    if not value:
        return None
    digits = re.sub(r"[^0-9]", "", value)[:8]  # OFX dates: YYYYMMDD[HHMMSS][.xxx][+TZ]
    if len(digits) < 8:
        return None
    try:
        return date(int(digits[0:4]), int(digits[4:6]), int(digits[6:8]))
    except ValueError:
        return None


def _decimal(value: str | None) -> Decimal | None:
    if value is None:
        return None
    try:
        return Decimal(value)
    except InvalidOperation:
        return None


def parse(content: bytes | str) -> ParsedStatement:
    text = content.decode("utf-8", "ignore") if isinstance(content, bytes) else content
    org = _leaf("ORG", text)
    acctid = _leaf("ACCTID", text)
    currency = (_leaf("CURDEF", text) or "USD").upper()[:3]

    # Balances — scope BALAMT to its own aggregate so LEDGERBAL and AVAILBAL don't collide.
    ledger_balance = ledger_as_of = available_balance = None
    if (m := _LEDGERBAL.search(text)):
        ledger_balance = _decimal(_leaf("BALAMT", m.group(1)))
        ledger_as_of = _parse_date(_leaf("DTASOF", m.group(1)))
    if (m := _AVAILBAL.search(text)):
        available_balance = _decimal(_leaf("BALAMT", m.group(1)))

    txns: list[ParsedTxn] = []
    for block in _STMTTRN.findall(text):
        fitid = _leaf("FITID", block)
        amount_raw = _leaf("TRNAMT", block)
        # Prefer the transaction (purchase) date when the institution emits it; fall back to the posted/
        # settled date. Note: Apple Card's OFX carries only DTPOSTED, so this is a no-op there.
        when = _parse_date(_leaf("DTUSER", block)) or _parse_date(_leaf("DTPOSTED", block))
        name = _leaf("NAME", block) or _leaf("MEMO", block) or "Transaction"
        if not fitid or amount_raw is None or when is None:
            continue
        try:
            amount = -Decimal(amount_raw)  # flip: OFX debit (−) → SplitBack outflow (+)
        except InvalidOperation:
            continue
        txns.append(ParsedTxn(fitid=fitid, date=when, amount=amount, description=name[:512]))
    return ParsedStatement(org=org, acctid=acctid, currency=currency, ledger_balance=ledger_balance,
                           available_balance=available_balance, ledger_as_of=ledger_as_of, transactions=txns)
