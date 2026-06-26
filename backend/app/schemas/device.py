from pydantic import BaseModel


class DeviceRegister(BaseModel):
    token: str
    platform: str = "ios"
    # Base64 X9.63 P-256 public key for E2E-encrypted (relay-blind) pushes; omitted by older builds.
    public_key: str | None = None
