from pydantic import BaseModel


class DeviceRegister(BaseModel):
    token: str
    platform: str = "ios"
