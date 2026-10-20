from datetime import datetime
from typing import Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class Coordinate(StrictModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class Obstacle(StrictModel):
    class_name: str = Field(max_length=40)
    position: Literal["left", "center", "right"]
    danger: Literal["low", "medium", "high"]
    confidence: float = Field(ge=0, le=1)


class NavigationContext(StrictModel):
    captured_at: datetime
    position: Coordinate | None = None
    gps_updated_at: datetime | None = None
    accuracy_meters: float | None = Field(default=None, ge=0, le=10000)
    heading_degrees: float | None = Field(default=None, ge=0, le=360)
    target_bearing: float | None = Field(default=None, ge=0, le=360)
    status: Literal["locating", "idle", "planning", "navigating", "offRoute", "poorGps", "arrived", "error", "paused"]
    route_message: str = Field(max_length=800)
    street_name: str = Field(default="", max_length=200)
    destination: Coordinate | None = None
    destination_name: str | None = Field(default=None, max_length=600)
    remaining_meters: float = Field(default=0, ge=0, le=10000000)
    walked_meters: float = Field(default=0, ge=0, le=10000000)
    next_instructions: list[str] = Field(default_factory=list, max_length=8)
    obstacles: list[Obstacle] = Field(default_factory=list, max_length=20)
    yolo_updated_at: datetime | None = None
    image_captured_at: datetime | None = None


class ChatRequest(StrictModel):
    request_id: UUID
    conversation_id: UUID
    message: str = Field(min_length=1, max_length=1500)
    mode: Literal["user", "proactive"] = "user"
    event: Literal["offRoute", "error", "poorGps", "headingUnavailable"] | None = None
    context: NavigationContext
    image_base64: str | None = Field(default=None, max_length=1200000)


class PairRequest(StrictModel):
    code: str = Field(min_length=1, max_length=128)
    device_id: UUID


class ToolArguments(StrictModel):
    action: Literal["set_destination", "refresh_route", "cancel_navigation", "repeat_instruction", "describe_location"]
    place_id: str | None


class FinalAnswer(StrictModel):
    kind: Literal["information", "route_status", "uncertain"]
    text: str = Field(max_length=700)
