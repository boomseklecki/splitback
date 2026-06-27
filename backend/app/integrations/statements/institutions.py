"""Maps a statement's issuing institution (OFX `<ORG>`) to a domain for logo/branding. A running list of the
exports we support — extend as we add issuers. The domain feeds `Account.institution_domain` (the logos
service resolves a brand logo from it, e.g. apple.com → the Apple logo)."""

# Lowercased ORG → brand domain.
_EXPORT_DOMAINS: dict[str, str] = {
    "apple card": "apple.com",
}


def resolve_domain(org: str | None) -> str | None:
    if not org:
        return None
    return _EXPORT_DOMAINS.get(org.strip().lower())
