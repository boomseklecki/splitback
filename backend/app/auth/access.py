"""Sign-in allowlist (email-only). Shared by `identity.resolve_user` (at sign-in) and `require_auth`
(every request) so an off-list account can neither obtain nor keep a session."""
from app.config import settings
from app.models import User


def allowed_set() -> set[str]:
    """The configured allowlist, lower-cased/stripped. Empty = no restriction."""
    return {e.strip().lower() for e in settings.auth_allowed_users if e and e.strip()}


def is_admin(caller: str | None) -> bool:
    """Whether the caller's identifier is configured as an admin (sees all people; reserved for gating
    settings/features). Empty ADMIN_USERS = nobody is admin."""
    if caller is None:
        return False
    return caller.strip().lower() in {a.strip().lower() for a in settings.admin_users if a and a.strip()}


def is_allowed(*, email: str | None, user: User | None) -> bool:
    """Whether this identity may authenticate. True when the allowlist is empty; otherwise the verified
    token `email` OR the existing user's stored email must be on the list (case-insensitive). Checking the
    stored email too means an Apple sign-in that omits the email claim still passes for a listed member."""
    allowed = allowed_set()
    if not allowed:
        return True
    candidates = set()
    if email:
        candidates.add(email.strip().lower())
    if user is not None and user.email:
        candidates.add(user.email.strip().lower())
    return bool(candidates & allowed)
