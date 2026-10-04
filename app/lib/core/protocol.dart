import 'dart:convert';
import 'dart:typed_data';
import 'model.dart';

String bleUuid(int n) => '5c5a000$n-8ee8-4e2d-a123-7d90b6cfc200';
const invalidPressure = -2147483648;

class Packet {
  final int flags, seq, uptimeLow, pressure, battery, soc, raw;
  const Packet(
    this.flags,
    this.seq,
    this.uptimeLow,
    this.pressure,
    this.battery,
    this.soc,
    this.raw,
  );
  factory Packet.decode(Uint8List bytes) {
    if (bytes.length != 20 ||
        bytes[0] != 2 ||
        bytes[17] != 0 ||
        bytes[1] & 0xc0 != 0) {
      throw const FormatException('Ismeretlen BLE-adatformátum');
    }
    final b = ByteData.sublistView(bytes);
    final p = Packet(
      b.getUint8(1),
      b.getUint32(2, Endian.little),
      b.getUint32(6, Endian.little),
      b.getInt32(10, Endian.little),
      b.getUint16(14, Endian.little),
      b.getUint8(16),
      b.getInt16(18, Endian.little),
    );
    if ((p.soc > 100 && p.soc != 255) ||
        (p.valid && p.pressure == invalidPressure)) {
      throw const FormatException('Hibás mérési érték');
    }
    return p;
  }
  bool get valid => flags & 1 != 0 && flags & 32 == 0;
  List<String> get quality => [
    if (!valid) 'sensor_error',
    if (flags & 2 == 0) 'rtc_invalid',
    if (flags & 8 != 0) 'sd_error',
    if (battery == 65535) 'battery_unknown',
  ];
  Json toJson() => {
    'flags': flags,
    'seq': seq,
    'uptime_low': uptimeLow,
    'pressure': pressure,
    'battery': battery,
    'soc': soc,
    'raw': raw,
  };
}

List<Uint8List> controlFrames(int id, Json command) {
  final bytes = utf8.encode(jsonEncode(command));
  if (id < 1 || id > 65535 || bytes.isEmpty || bytes.length > 512) {
    throw const FormatException('Túl nagy BLE-parancs');
  }
  return [
    for (var offset = 0; offset < bytes.length; offset += 14)
      () {
        final end = (offset + 14).clamp(0, bytes.length);
        final b = ByteData(6 + end - offset)
          ..setUint16(0, id, Endian.little)
          ..setUint16(2, offset, Endian.little)
          ..setUint16(4, bytes.length, Endian.little);
        final out = b.buffer.asUint8List();
        out.setRange(6, out.length, bytes.sublist(offset, end));
        return out;
      }(),
  ];
}

class DeviceClock {
  final String boot, segmentId;
  final int anchorUptime, anchorUtc, uncertainty;
  int? lastSeq;
  int lastUptime;
  DeviceClock(this.boot, this.anchorUptime, this.anchorUtc, this.uncertainty)
    : segmentId = ids.v4(),
      lastUptime = anchorUptime;
  int unwrap(int low) {
    var full = (lastUptime & ~0xffffffff) | low;
    if (full - lastUptime > 0x80000000) full -= 0x100000000;
    if (lastUptime - full > 0x80000000) full += 0x100000000;
    lastUptime = full;
    return full;
  }

  Json segment(String device) => {
    'id': segmentId,
    'device_id': device,
    'boot_id': boot,
    'uptime_anchor_ms': anchorUptime,
    'utc_anchor': utc(anchorUtc),
    'uncertainty_ms': uncertainty,
    'source': 'phone',
  };
  int utcAt(int uptime) => anchorUtc + uptime - anchorUptime;
  DeviceClock newSegment() =>
      DeviceClock(boot, anchorUptime, anchorUtc, uncertainty)
        ..lastUptime = lastUptime;
}

Json decodeObject(Uint8List bytes) {
  if (bytes.length > 512) throw const FormatException('Túl hosszú BLE-válasz');
  return object(jsonDecode(utf8.decode(bytes)));
}
