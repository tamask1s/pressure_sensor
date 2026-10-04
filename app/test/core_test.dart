import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pressure_field/core/protocol.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/core/location.dart';
import 'package:pressure_field/core/grid.dart';
import 'package:pressure_field/core/csv.dart';

Json fix(
  int time, {
  double accuracy = 2,
  String segment = 'phone',
  double? speed = 2,
}) => {
  'id': 'fix-$time',
  'segment_id': segment,
  'captured_at': utc(time),
  'latitude': 47.0,
  'longitude': 19.0,
  'accuracy_m': accuracy,
  'speed_mps': speed,
};
Json sample(int time, int? pressure, {Json? location}) => {
  'device_id': 'hps-001122334455',
  'boot_id': 'boot',
  'seq': time,
  'time_segment_id': 'clock',
  'captured_at': utc(time),
  'pressure_pa': pressure,
  'raw_count': 0,
  'flags': <String>[],
  'location': location,
};

void main() {
  test('Shared BLE and claim fixtures match the client codecs', () {
    final fixture = object(
      jsonDecode(File('../contracts/fixtures.json').readAsStringSync()),
    );
    Uint8List hex(String value) => Uint8List.fromList([
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ]);
    final packet = object(fixture['ble_packet']);
    final p = Packet.decode(hex(packet['hex'] as String));
    expect(p.pressure, packet['pressure_pa']);
    expect(p.raw, packet['raw_count']);
    expect(p.seq, packet['seq']);
    expect(p.uptimeLow, packet['uptime_low']);
    final c = object(fixture['claim']);
    final message = [
      ...utf8.encode(
        'HPS-CLAIM-v1\n${c['device_id']}\n${c['account_id']}\n${c['challenge_id']}\n',
      ),
      ...base64Url.decode(base64Url.normalize(c['nonce'] as String)),
    ];
    expect(message, hex(c['message_hex'] as String));
    expect(
      base64Url
          .encode(
            Hmac(sha256, hex(c['secret_hex'] as String)).convert(message).bytes,
          )
          .replaceAll('=', ''),
      c['proof'],
    );
  });
  test('BLE packet preserves zero, signed raw count and uint32 sequence', () {
    final bytes = Uint8List(20), b = ByteData.sublistView(bytes);
    b.setUint8(0, 2);
    b.setUint8(1, 1);
    b.setUint32(2, 0xffffffff, Endian.little);
    b.setUint32(6, 0x12345678, Endian.little);
    b.setUint16(14, 65535, Endian.little);
    b.setUint8(16, 255);
    b.setInt16(18, -16000, Endian.little);
    final p = Packet.decode(bytes);
    expect(p.pressure, 0);
    expect(p.valid, true);
    expect(p.raw, -16000);
    expect(p.seq, 0xffffffff);
    expect(p.uptimeLow, 0x12345678);
    expect(p.quality, contains('battery_unknown'));
    bytes[17] = 1;
    expect(() => Packet.decode(bytes), throwsFormatException);
    expect(() => Packet.decode(Uint8List(4)), throwsFormatException);
  });
  test('BLE control fragments fit the minimum ATT MTU', () {
    final command = {
          'op': 'claim',
          'nonce': 'a' * 22,
          'account_id': 'b' * 36,
          'challenge_id': 'c' * 36,
        },
        frames = controlFrames(27, command),
        all = <int>[];
    for (final f in frames) {
      final b = ByteData.sublistView(f);
      expect(f.length, lessThanOrEqualTo(20));
      expect(b.getUint16(0, Endian.little), 27);
      expect(b.getUint16(2, Endian.little), all.length);
      all.addAll(f.sublist(6));
      expect(
        b.getUint16(4, Endian.little),
        utf8.encode(jsonEncode(command)).length,
      );
    }
    expect(jsonDecode(utf8.decode(all)), command);
  });
  test('Uptime wrap keeps UTC monotonic', () {
    final clock = DeviceClock('boot', 0xfffffff0, 100000, 20);
    expect(clock.unwrap(0xfffffff8), 0xfffffff8);
    expect(clock.utcAt(clock.unwrap(16)), 100032);
    final nextSession = clock.newSegment();
    expect(nextSession.segmentId, isNot(clock.segmentId));
    expect(nextSession.utcAt(nextSession.unwrap(32)), 100048);
  });
  test('GPS needs two close, accurate fixes in one time segment', () {
    expect(interpolate([fix(0), fix(1000)], 500)?['latitude'], 47);
    expect(interpolate([fix(0), fix(3000)], 500), isNull);
    expect(interpolate([fix(0), fix(1000, accuracy: 20)], 500), isNull);
    expect(interpolate([fix(0), fix(1000, segment: 'new')], 500), isNull);
    expect(interpolate([fix(0)], 500), isNull);
    expect(
      finalizeLocation(sample(500, 0), [], true, 20)['flags'],
      contains('gps_missing'),
    );
    final noGps = finalizeLocation(sample(500, 0), [], true, 20);
    expect(noGps['pressure_pa'], 0);
    expect(noGps['captured_at'], utc(500));
    expect(noGps['location'], isNull);
    expect(
      finalizeLocation(
        sample(500, 0),
        [fix(0), fix(1000)],
        true,
        200,
      )['location'],
      isNull,
    );
  });
  test('GPS preserves sub-millisecond bounds and interpolation precision', () {
    final a = fix(1000, speed: 0)
          ..['captured_at'] = '1970-01-01T00:00:01.000900Z',
        b = fix(2000, speed: 10)
          ..['captured_at'] = '1970-01-01T00:00:02.000100Z';
    // A sample just before the first fix has no bracket, even in the same ms.
    expect(interpolate([a, b], 1000), isNull);
    expect(
      interpolate([a, b], 1500)!['speed_mps'],
      closeTo(10 * 499100 / 999200, 1e-12),
    );
    b['captured_at'] = '1970-01-01T00:00:03.000901Z';
    expect(interpolate([a, b], 2000), isNull);
  });
  test(
    'Grid weighs channels then sessions equally, independent of sample density',
    () {
      final fixes = [fix(0), fix(1000)],
          grid = PressureGrid(GridSpec.at(47, 19, 10), {
            'one': fixes,
            'two': fixes,
          });
      final loc = interpolate(fixes, 500)!;
      for (var i = 0; i < 10; i++) {
        grid.add('one', 'A', sample(i * 100, 0, location: loc));
      }
      grid.add('one', 'B', sample(500, 20000000, location: loc));
      grid.add('two', 'A', sample(500, 20000000, location: loc));
      grid.add('two', 'B', sample(500, 20000000, location: loc));
      final result = grid.finish(), cell = objects(result['cells']).single;
      expect(result['grid_srid'], 32634);
      expect(cell['mean_pa'], 15000000);
      expect(cell['sample_count'], 13);
      expect(cell['session_count'], 2);
      expect(cell['min_pa'], 0);
      expect(cell['max_pa'], 20000000);
      final spec = GridSpec.at(47, 19, 10),
          p = spec.project(47, 19),
          back = spec.unproject(p.x, p.y);
      expect(back[0], closeTo(19, 1e-8));
      expect(back[1], closeTo(47, 1e-8));
    },
  );
  test('CSV keeps GPS-less pressure and timestamp', () async {
    final data = sample(1000, 0);
    final bytes = <int>[];
    await for (final b in csvBytes(Stream.value([data]))) {
      bytes.addAll(b);
    }
    final text = utf8.decode(bytes);
    expect(text, contains('1970-01-01T00:00:01.000Z'));
    expect(text, contains('"0","0.0"'));
    expect(text, contains('latitude,longitude'));
  });
}
