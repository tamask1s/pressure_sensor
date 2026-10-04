# BLE v2

UUID base: `5c5a0000-8ee8-4e2d-a123-7d90b6cfc200`. Service suffix (first field) `5c5a0001`, Sample `0002`, Info `0003`, Control `0004`, Result `0005`.

Sample: 20 bytes little-endian: version u8=2, flags u8, seq u32, uptime_ms_low u32, pressure_pa i32, battery_mv u16, soc u8, reserved u8=0, raw i16. Flags: bit0 pressure valid, bit1 RTC valid, bit2 SD active, bit3 SD error, bit4 battery low, bit5 sensor error. Invalid pressure INT32_MIN; unknown battery 65535, SOC 255. One new sequence per 100 ms attempt. Duplicate sequence is not a new sample.

Info is a long-readable UTF-8 JSON object, maximum 512 bytes. Fields: device_id, boot_id (UUID), uptime_ms, firmware_version, protocol_version, sensor_serial, provisioned, pairing_open, range_min_pa, range_max_pa, calibration_verified, sd_dropped, ble_dropped, supervision_ms. Pressure range is an installation setting, never inferred from the model family.

Control: write-with-response, encrypted authenticated bond. Each write: request_id u16, offset u16, total_length u16, followed by at most 14 JSON bytes. Maximum message 512 bytes, exact offsets, 2 s assembly timeout. One request at a time; IDs 1–65535, independent per connection. Result holds `{id,ok,...}` or `{id,ok:false,error}` as long-readable JSON; a 2-byte little-endian ID notification announces availability. Polling Result by matching ID also recovers a missed notification. Execute timeout 5 s, no blind retry of mutating commands.

Commands: `{op:"time"}` → uptime_ms, utc_ms|null; `{op:"set_time",utc_ms}` → uptime_ms, utc_ms, rtc_valid; `{op:"identify"}` → 3 s LED indication; `{op:"sd",enabled:bool}` → enabled; `{op:"claim",account_id,challenge_id,nonce}` → proof. Claim HMAC bytes follow `../service/INTERFACE.md`; it also requires the 120 s physical pairing window. No device secret is readable through GATT. New pairing is only accepted during that window, with the provisioned six-digit PIN. Info remains public; sample and control require an authenticated encrypted bond.

Disconnect clears fragment state and pending commands. Invalid fragments never execute. Result remains stable until the next complete command. Time replies sample uptime and UTC together; UTC validity never gates pressure acquisition.
