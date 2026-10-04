"""Version 1 wire models; unknown fields and non-finite numbers are rejected."""
from datetime import datetime, timezone
from typing import Annotated, Literal
from uuid import UUID
from pydantic import BaseModel, ConfigDict, Field, AfterValidator, model_validator

def utc(v):
    if v.tzinfo is None:
        raise ValueError('UTC offset required')
    return v.astimezone(timezone.utc)

def uid(v):
    if str(UUID(v)) != v:
        raise ValueError('canonical UUID required')
    return v

ID = Annotated[str, AfterValidator(uid)]
Time = Annotated[datetime, AfterValidator(utc)]
DeviceID = Annotated[str, Field(pattern=r'^hps-[0-9a-f]{12}$')]
Count = Annotated[int, Field(strict=True, ge=0, le=9007199254740991)]
Seq = Annotated[int, Field(strict=True, ge=0, le=4294967295)]
Pressure = Annotated[int, Field(strict=True, ge=-2147483648, le=2147483647)]
Name = Annotated[str, Field(min_length=1, max_length=120)]
class Model(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)

class Credentials(Model):
    email: Annotated[str, Field(min_length=3, max_length=254, pattern=r'^[^\s@]+@[^\s@]+\.[^\s@]+$')]
    password: Annotated[str, Field(min_length=12, max_length=256)]
class Login(Credentials):
    client_kind: Literal['native', 'web']
class Email(Model):
    email: Annotated[str, Field(min_length=3, max_length=254)]
class Token(Model):
    token: Annotated[str, Field(min_length=16, max_length=200)]
class Reset(Token):
    new_password: Annotated[str, Field(min_length=12, max_length=256)]
class Refresh(Model):
    refresh_token: Annotated[str, Field(min_length=16, max_length=200)]
class Password(Model):
    password: Annotated[str, Field(max_length=256)]
class Rename(Model):
    name: Name
class Rig(Rename):
    device_a_id: DeviceID
    device_b_id: DeviceID
    expected_revision: Annotated[int, Field(ge=0)]
class Archive(Model):
    archived: Literal[True]
    expected_revision: Annotated[int, Field(ge=1)]
class Challenge(Model):
    device_id: DeviceID
class Proof(Model):
    challenge_id: ID
    proof: Annotated[str, Field(pattern=r'^[A-Za-z0-9_-]{43}$')]
class Calibration(Model):
    profile_id: Name
    sensor_serial: Annotated[int, Field(ge=0, le=4294967295)]
    range_min_pa: Annotated[int, Field(ge=0, le=60000000)]
    range_max_pa: Annotated[int, Field(ge=1, le=60000000)]
    scale: Annotated[float, Field(gt=0, le=100)]
    offset_pa: Annotated[float, Field(ge=-60000000, le=60000000)]
    verified: bool
    @model_validator(mode='after')
    def ordered(self):
        if self.range_min_pa >= self.range_max_pa: raise ValueError('invalid range')
        return self
class Snapshot(Model):
    device_id: DeviceID
    ownership_id: ID
    role: Literal['A', 'B']
    calibration: Calibration
class SessionStart(Model):
    collector_id: ID
    rig_id: ID
    rig_revision: Annotated[int, Field(ge=0)]
    name: Name
    started_at: Time
    gps_enabled: bool
    devices: Annotated[list[Snapshot], Field(min_length=2, max_length=2)]
class Segment(Model):
    id: ID
    device_id: DeviceID | None = None
    boot_id: ID | None = None
    uptime_anchor_ms: Count
    utc_anchor: Time
    uncertainty_ms: Annotated[int, Field(ge=0, le=9007199254740991)]
    source: Literal['phone', 'rtc']
    @model_validator(mode='after')
    def pair(self):
        if (self.device_id is None) != (self.boot_id is None): raise ValueError('device and boot required together')
        if self.device_id is None and self.source != 'phone': raise ValueError('GPS requires phone time')
        return self
class Fix(Model):
    id: ID
    segment_id: ID
    captured_at: Time
    latitude: Annotated[float, Field(ge=-90, le=90)]
    longitude: Annotated[float, Field(ge=-180, le=180)]
    accuracy_m: Annotated[float, Field(ge=0, le=100000)]
    speed_mps: Annotated[float, Field(ge=0, le=1000)] | None = None
    heading_deg: Annotated[float, Field(ge=0, lt=360)] | None = None
class Location(Model):
    latitude: Annotated[float, Field(ge=-90, le=90)]
    longitude: Annotated[float, Field(ge=-180, le=180)]
    accuracy_m: Annotated[float, Field(ge=0, le=10)]
    speed_mps: Annotated[float, Field(ge=0, le=1000)] | None = None
    fix_before_id: ID
    fix_after_id: ID
    method: Literal['interpolated']
Flag = Literal['sensor_error','pressure_out_of_range','rtc_invalid','battery_unknown','sd_error','gps_disabled','gps_missing','gps_inaccurate','time_uncertain','stationary','speed_unknown']
class Sample(Model):
    device_id: DeviceID
    boot_id: ID
    seq: Seq
    time_segment_id: ID
    uptime_ms: Count
    captured_at: Time
    raw_count: Annotated[int, Field(strict=True, ge=-32768, le=32767)] | None
    pressure_pa: Pressure | None
    battery_mv: Annotated[int, Field(ge=0, le=65535)] | None
    soc_pct: Annotated[int, Field(ge=0, le=100)] | None
    flags: Annotated[list[Flag], Field(max_length=11)]
    location: Location | None
    @model_validator(mode='after')
    def sensor(self):
        if (self.pressure_pa is None or self.raw_count is None) != ('sensor_error' in self.flags):
            raise ValueError('sensor error and null values must agree')
        if 'sensor_error' in self.flags and (self.pressure_pa is not None or self.raw_count is not None):
            raise ValueError('sensor error requires null values')
        return self
class Batch(Model):
    batch_id: ID
    time_segments: Annotated[list[Segment], Field(max_length=20)] = []
    gps_fixes: Annotated[list[Fix], Field(max_length=100)] = []
    samples: Annotated[list[Sample], Field(max_length=500)] = []
class Gap(Model):
    device_id: DeviceID
    boot_id: ID | None = None
    from_seq: Seq | None = None
    to_seq: Seq | None = None
    started_at: Time
    ended_at: Time
    reason: Annotated[str, Field(min_length=1, max_length=120)]
class Complete(Model):
    ended_at: Time
    status: Literal['completed', 'interrupted']
    expected_samples_by_device: dict[DeviceID, Count]
    gaps: Annotated[list[Gap], Field(max_length=1000)] = []
class Observation(Model):
    device_id: DeviceID
    boot_id: ID | None = None
    ble_connected: bool
    last_seq: Seq | None = None
    sample_age_ms: Count | None = None
    pressure_pa: Pressure | None = None
    battery_mv: Annotated[int, Field(ge=0, le=65535)] | None = None
    soc_pct: Annotated[int, Field(ge=0, le=100)] | None = None
    sensor_ok: bool
    sd_state: Annotated[str, Field(max_length=40)]
class Presence(Model):
    lease_id: ID | None = None
    heartbeat_seq: Count
    observed_at: Time
    session_id: ID | None = None
    devices: Annotated[list[Observation], Field(min_length=1, max_length=2)]
class Provision(Model):
    device_id: DeviceID
    secret_hex: Annotated[str, Field(pattern=r'^[0-9a-f]{64}$')]
    sensor_serial: Annotated[int, Field(ge=0, le=4294967295)]
    protocol_version: Literal[2]
    firmware_version: str | None = None
    calibration: Calibration
