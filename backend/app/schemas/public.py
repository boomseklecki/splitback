from pydantic import BaseModel


class ServerInfo(BaseModel):
    app: str
    version: str
    name: str  # friendly label for the confirm screen (server-settings public_hostname, else app_name)
    requires_auth: bool  # whether the gate shows (auth providers configured, or auth_required/api_tokens)
    auth_providers: list[str]  # configured sign-in options, e.g. ["apple", "google", "splitwise"]
    demo: bool = False  # a demo backend: the app shows guest "Start the demo" + a sample-data banner
