from pydantic import BaseModel


class ServerInfo(BaseModel):
    app: str
    version: str
    name: str  # friendly label for the confirm screen (public_hostname or app_name)
    requires_auth: bool  # whether a token is needed (auth_required or api_tokens configured)
    auth_providers: list[str]  # configured sign-in options, e.g. ["apple", "google", "splitwise"]
    demo: bool = False  # a demo backend: the app shows guest "Start the demo" + a sample-data banner
