"""OFX statement parsing: STMTTRN extraction, the amount sign flip (OFX debit → SplitBack outflow), date +
FITID + account meta. Pure (no DB)."""
from datetime import date
from decimal import Decimal

from app.integrations.statements import ofx

# A minimal Apple-Card-style OFX 1.x (SGML) statement: two purchases + one payment credit.
SAMPLE = """OFXHEADER:100
DATA:OFXSGML
VERSION:102

<OFX>
<SIGNONMSGSRSV1><SONRS><FI><ORG>Apple Card</ORG><FID>1</FID></FI></SONRS></SIGNONMSGSRSV1>
<CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS>
<CURDEF>USD
<CCACCTFROM><ACCTID>xxxxxxxxxxxx4321</ACCTID></CCACCTFROM>
<BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260601120000<TRNAMT>-42.50<FITID>AC-1<NAME>BURRITO PALACE</STMTTRN>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260603<TRNAMT>-9.99<FITID>AC-2<NAME>STREAMING CO<MEMO>monthly</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260610<TRNAMT>200.00<FITID>AC-3<NAME>PAYMENT THANK YOU</STMTTRN>
</BANKTRANLIST>
<LEDGERBAL><BALAMT>-621.28<DTASOF>20260626120000</LEDGERBAL>
<AVAILBAL><BALAMT>7878.72<DTASOF>20260626120000</AVAILBAL>
</CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1>
</OFX>
"""


def test_parses_meta_and_transactions():
    s = ofx.parse(SAMPLE)
    assert s.org == "Apple Card"
    assert s.acctid == "xxxxxxxxxxxx4321"
    assert s.currency == "USD"
    assert len(s.transactions) == 3


def test_parses_balances_and_as_of():
    s = ofx.parse(SAMPLE)
    assert s.ledger_balance == Decimal("-621.28")      # raw OFX (negative-when-owed); router flips
    assert s.available_balance == Decimal("7878.72")   # available credit (positive), stored as-is
    assert s.ledger_as_of == date(2026, 6, 26)


def test_resolve_domain():
    from app.integrations.statements.institutions import resolve_domain
    assert resolve_domain("Apple Card") == "apple.com"
    assert resolve_domain("apple card") == "apple.com"
    assert resolve_domain("Unknown Bank") is None
    assert resolve_domain(None) is None


def test_amount_sign_flips_to_outflow_positive():
    by_id = {t.fitid: t for t in ofx.parse(SAMPLE).transactions}
    assert by_id["AC-1"].amount == Decimal("42.50")   # OFX -42.50 purchase → +42.50 outflow
    assert by_id["AC-3"].amount == Decimal("-200.00")  # OFX +200 payment → -200 inflow


def test_fields_date_and_description():
    t = next(t for t in ofx.parse(SAMPLE).transactions if t.fitid == "AC-1")
    assert t.date == date(2026, 6, 1)
    assert t.description == "BURRITO PALACE"


def test_prefers_dtuser_over_dtposted():
    # When an institution emits DTUSER (purchase date), prefer it over the later DTPOSTED (settled date).
    # Apple Card omits DTUSER, so the SAMPLE rows above exercise the DTPOSTED fallback.
    block = ("<OFX><STMTTRN><DTUSER>20260612<DTPOSTED>20260614120000"
             "<TRNAMT>-9.99<FITID>X<NAME>WITH DTUSER</STMTTRN></OFX>")
    t = ofx.parse(block).transactions[0]
    assert t.date == date(2026, 6, 12)


def test_falls_back_to_memo_when_no_name():
    # Drop NAME, keep MEMO → description from MEMO.
    block = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-1.00<FITID>X<MEMO>FROM MEMO</STMTTRN></OFX>"
    t = ofx.parse(block).transactions[0]
    assert t.description == "FROM MEMO"


def test_name_memo_flipped_bank_prefers_merchant_in_memo():
    # Some banks put the payment *method* in NAME and the merchant in MEMO. Lead with the merchant.
    block = ("<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-4.50<FITID>X"
             "<NAME>DEBIT CARD PURCHASE 1234<MEMO>STARBUCKS #123 SEATTLE</STMTTRN></OFX>")
    t = ofx.parse(block).transactions[0]
    assert t.description.startswith("STARBUCKS #123 SEATTLE")        # merchant first, not the method
    assert "STARBUCKS" in t.description


def test_boilerplate_name_containing_merchant_collapses_to_merchant():
    # NAME is boilerplate that *includes* the MEMO merchant → just the clean merchant, no duplication.
    block = ("<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-4.50<FITID>X"
             "<NAME>POS DEBIT STARBUCKS<MEMO>STARBUCKS</STMTTRN></OFX>")
    t = ofx.parse(block).transactions[0]
    assert t.description == "STARBUCKS"


def test_normal_bank_keeps_name_and_appends_complementary_memo():
    # Common case: NAME holds the merchant (not boilerplate). Keep it; append MEMO detail when distinct.
    block = ("<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-9.99<FITID>X"
             "<NAME>STREAMING CO<MEMO>monthly</STMTTRN></OFX>")
    t = ofx.parse(block).transactions[0]
    assert t.description == "STREAMING CO — monthly"


def test_name_only_unchanged():
    block = "<OFX><STMTTRN><DTPOSTED>20260601<TRNAMT>-1.00<FITID>X<NAME>WHOLE FOODS</STMTTRN></OFX>"
    assert ofx.parse(block).transactions[0].description == "WHOLE FOODS"


def test_skips_incomplete_rows():
    block = "<OFX><STMTTRN><TRNAMT>-1.00<NAME>NO FITID</STMTTRN></OFX>"  # missing FITID + date
    assert ofx.parse(block).transactions == []


if __name__ == "__main__":
    from tests._runner import run

    run(dict(globals()))
