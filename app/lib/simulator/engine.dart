import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../core/model.dart';
import '../core/protocol.dart';

const simulatorPort = 47832;

List<Json> newSimulatorDevices() {
  final random = Random.secure();
  return List.generate(2, (_) {
    String hex(int count) => List.generate(
      count,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final id = 'hps-02${hex(5)}', serial = random.nextInt(0x7fffffff);
    return {
      'device_id': id,
      'secret_hex': hex(32),
      'sensor_serial': serial,
      'protocol_version': 2,
      'calibration': calibration({
        'device_id': id,
        'sensor_serial': serial,
        'range_min_pa': 0,
        'range_max_pa': 20000000,
        'calibration_verified': true,
      }),
    };
  });
}

class SimDevice {
  final Json registration;
  final int index;
  String boot = ids.v4();
  int bootAt = 0, seq = 0, pairingUntil = 0;
  int? utcOffset;
  bool online = true, sensorError = false, sd = false;
  double? pressureBar;
  SimDevice(this.registration, this.index) {
    if (!RegExp(r'^hps-[0-9a-f]{12}$').hasMatch(id) ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(registration['secret_hex'] as String? ?? '') ||
        registration['protocol_version'] != 2 ||
        registration['sensor_serial'] is! int ||
        registration['calibration']?['range_min_pa'] != 0 ||
        registration['calibration']?['range_max_pa'] != 20000000) {
      throw const FormatException('Hibás szimulátor-eszközfájl');
    }
  }
  String get id => registration['device_id'] as String;
  Json info(int now) => {
    'device_id': id,
    'boot_id': boot,
    'uptime_ms': now - bootAt,
    'firmware_version': 'sim-2.0.0',
    'protocol_version': 2,
    'sensor_serial': registration['sensor_serial'],
    'provisioned': true,
    'pairing_open': now < pairingUntil,
    'range_min_pa': 0,
    'range_max_pa': 20000000,
    'calibration_verified': true,
    'sd_dropped': 0,
    'ble_dropped': 0,
    'supervision_ms': 6000,
  };
  Uint8List sample(int now, double terrain) {
    final requested = ((pressureBar ?? terrain + index * 3) * 100000)
        .round()
        .clamp(0, 20000000);
    final raw = (requested * 32000 / 20000000 - 16000).round();
    final pa = ((raw + 16000) * 20000000 / 32000).round();
    final bytes = ByteData(20)
      ..setUint8(0, 2)
      ..setUint8(
        1,
        (sensorError ? 32 : 1) | (utcOffset == null ? 0 : 2) | (sd ? 4 : 0),
      )
      ..setUint32(2, seq++, Endian.little)
      ..setUint32(6, (now - bootAt) & 0xffffffff, Endian.little)
      ..setInt32(10, sensorError ? invalidPressure : pa, Endian.little)
      ..setUint16(14, 3900 - index * 20, Endian.little)
      ..setUint8(16, 78 - index)
      ..setInt16(18, sensorError ? -32768 : raw, Endian.little);
    return bytes.buffer.asUint8List();
  }

  Json command(Json command, int now) {
    switch (command['op']) {
      case 'set_time':
        final utcMs = command['utc_ms'];
        if (utcMs is! int || utcMs < 1577836800000 || utcMs > 4102444799999) {
          throw const UserError('Érvénytelen idő');
        }
        utcOffset = utcMs - (now - bootAt);
        return {'uptime_ms': now - bootAt, 'utc_ms': utcMs, 'rtc_valid': true};
      case 'time':
        return {
          'uptime_ms': now - bootAt,
          'utc_ms': utcOffset == null ? null : utcOffset! + now - bootAt,
        };
      case 'identify':
        return {'identified': true};
      case 'sd':
        if (command['enabled'] is! bool) throw const FormatException('enabled');
        sd = command['enabled'] as bool;
        return {'enabled': sd};
      case 'claim':
        if (now >= pairingUntil) {
          throw const UserError('Nyisd meg a szimulátor párosítási ablakát.');
        }
        for (final key in ['account_id', 'challenge_id']) {
          if (!RegExp(
            r'^[0-9a-fA-F-]{36}$',
          ).hasMatch(command[key] as String? ?? '')) {
            throw const FormatException('Hibás claim-azonosító');
          }
        }
        final nonce = base64Url.decode(
          base64Url.normalize(command['nonce'] as String),
        );
        if (nonce.length != 16) throw const FormatException('Hibás nonce');
        final hex = registration['secret_hex'] as String;
        final key = [
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ];
        final bytes = [
          ...utf8.encode(
            'HPS-CLAIM-v1\n$id\n${command['account_id']}\n${command['challenge_id']}\n',
          ),
          ...nonce,
        ];
        return {
          'proof': base64Url
              .encode(Hmac(sha256, key).convert(bytes).bytes)
              .replaceAll('=', ''),
        };
      default:
        throw const UserError('Ismeretlen eszközparancs');
    }
  }

  void reboot(int now) {
    boot = ids.v4();
    bootAt = now;
    seq = 0;
    utcOffset = null;
    pairingUntil = 0;
  }
}

class Simulation {
  final List<SimDevice> devices;
  final Stopwatch clock = Stopwatch()..start();
  bool gps = true, moving = true;
  double distance = 0;
  int _lastTick = 0;
  Simulation(List<Json> registry)
    : devices = [
        for (var i = 0; i < registry.length; i++) SimDevice(registry[i], i),
      ] {
    if (devices.length != 2 || devices[0].id == devices[1].id) {
      throw const FormatException('Két különböző szimulált eszköz szükséges.');
    }
  }
  int get now => clock.elapsedMilliseconds;
  // Repeated 180 m rows, 20 m turns; 10 km/h, in an example field in Hungary.
  (double, double) get position {
    final d = distance % 8000, row = (d / 200).floor(), along = d % 200;
    final north = row.isEven ? min(along, 180.0) : 180 - min(along, 180.0);
    final turn = max(0, along - 180);
    final east = row < 20 ? row * 20 + turn : (40 - row) * 20 - turn;
    return (east.toDouble(), north.toDouble());
  }

  void advance() {
    final t = now;
    if (moving) distance += (t - _lastTick) / 1000 * (10 / 3.6);
    _lastTick = t;
  }

  double get terrain {
    final (east, north) = position;
    return 85 + 45 * sin(east / 42) + 30 * cos(north / 45);
  }

  Json fix() {
    final (east, north) = position;
    return {
      'id': ids.v4(),
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'latitude': 47.1 + north / 111320,
      'longitude': 19.3 + east / (111320 * cos(47.1 * pi / 180)),
      'accuracy_m': 1.5,
      'speed_mps': moving ? 10 / 3.6 : 0.0,
      'heading_deg': distance % 200 >= 180
          ? (distance % 8000 < 4000 ? 90.0 : 270.0)
          : ((distance / 200).floor().isEven ? 0.0 : 180.0),
    };
  }

  Json get state => {
    'gps': gps,
    'moving': moving,
    'devices': [
      for (final d in devices)
        {
          'id': d.id,
          'role': d.index == 0 ? 'A' : 'B',
          'online': d.online,
          'sensor_error': d.sensorError,
          'pressure_bar': d.pressureBar,
          'pairing_open': now < d.pairingUntil,
        },
    ],
  };
  SimDevice device(String id) => devices.firstWhere(
    (d) => d.id == id,
    orElse: () => throw const UserError('Ismeretlen szimulált eszköz'),
  );
  void control(Json c) {
    switch (c['action']) {
      case 'gps':
        gps = c['enabled'] as bool;
        break;
      case 'moving':
        moving = c['enabled'] as bool;
        break;
      case 'pairing':
        for (final d in devices) {
          d.pairingUntil = now + 120000;
        }
        break;
      case 'device':
        final d = device(c['device_id'] as String);
        if (c.containsKey('online')) d.online = c['online'] as bool;
        if (c.containsKey('sensor_error')) {
          d.sensorError = c['sensor_error'] as bool;
        }
        if (c.containsKey('pressure_bar')) {
          final bar = c['pressure_bar'];
          if (bar != null &&
              (bar is! num || !bar.isFinite || bar < 0 || bar > 200)) {
            throw const UserError('A nyomás 0–200 bar lehet.');
          }
          d.pressureBar = (bar as num?)?.toDouble();
        }
        if (c['reboot'] == true) d.reboot(now);
        break;
      default:
        throw const UserError('Ismeretlen szimulátorparancs');
    }
  }
}
