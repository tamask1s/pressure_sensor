import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pressure_field/controller.dart';
import 'package:pressure_field/core/grid.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/core/protocol.dart';
import 'package:pressure_field/measurement/capture_native.dart';
import 'package:pressure_field/measurement/simulator_hub.dart';
import 'package:pressure_field/platform/recording.dart';
import 'package:pressure_field/simulator/engine.dart';
import 'package:pressure_field/simulator/server.dart';
import 'package:pressure_field/storage/store_api.dart';
import 'package:pressure_field/storage/store_native.dart';
import 'package:pressure_field/sync/api.dart';
import 'package:pressure_field/sync/uploader.dart';

Future<void> until(FutureOr<bool> Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The simulated device did not reach the expected state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<List<Json>> records(Store store, String session, String kind) async => [
  await for (final page in store.records(session, kind)) ...page,
];

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      nativeRecording,
      (_) async => null,
    );
  });
  test('One-click preparation creates and reuses the simulated pair', () async {
    final temp = await Directory.systemTemp.createTemp(
      'pressure-simulator-ui-',
    );
    final store = await openStore(
      'simulator-ui',
      file: '${temp.path}/test.sqlite',
    );
    final server = SimulatorServer(Simulation(newSimulatorDevices()));
    await server.start(port: 0);
    final app = AppController(simulated: true, simulationPort: server.port)
      ..account = {'id': 'local', 'email': 'Helyi használat'}
      ..store = store;
    addTearDown(() async {
      await app.logout();
      app.dispose();
      await server.dispose();
      await temp.delete(recursive: true);
    });
    await app.prepareSimulation();
    expect(app.devices, hasLength(2));
    expect(app.rigs, hasLength(1));
    expect(app.channels.values.every((c) => c['connected'] == true), true);
    final rig = app.rig!['id'];
    await app.prepareSimulation();
    expect(app.devices, hasLength(2));
    expect(app.rigs, hasLength(1));
    expect(app.rig!['id'], rig);
    expect((await store.meta('selection'))!['rig_id'], rig);
  });
  test(
    'Simulator packets preserve calibration, faults, boot and claim contract',
    () async {
      final fixture = object(
        jsonDecode(await File('../contracts/fixtures.json').readAsString()),
      );
      final claim = object(fixture['claim']);
      final r = newSimulatorDevices().first
        ..['device_id'] = claim['device_id']
        ..['secret_hex'] = claim['secret_hex'];
      final d = SimDevice(r, 0)..pairingUntil = 120000;
      expect(d.command({'op': 'claim', ...claim}, 0)['proof'], claim['proof']);
      expect(
        () => d.command({'op': 'claim', ...claim}, 120000),
        throwsA(isA<UserError>()),
      );
      for (final bar in [0.0, 83.23456, 200.0]) {
        d.pressureBar = bar;
        final p = Packet.decode(d.sample(100, 0));
        expect(p.pressure, ((p.raw + 16000) / 32000 * 20000000).round());
        expect(p.valid, true);
      }
      d.sensorError = true;
      final fault = Packet.decode(d.sample(200, 0));
      expect(fault.pressure, invalidPressure);
      expect(fault.quality, contains('sensor_error'));
      final boot = d.boot;
      d.reboot(300);
      expect(d.boot, isNot(boot));
      expect(Packet.decode(d.sample(400, 0)).seq, 0);
      expect(d.info(400)['uptime_ms'], 100);
      final a = Api('https://example.invalid'),
          b = Api('https://example.invalid', vaultNamespace: 'sim:47832:');
      expect(a.vaultKey, isNot(b.vaultKey));
      a.close();
      b.close();
    },
  );

  test(
    'Loopback rejects browser access and reconnects after simulator restart',
    () async {
      final registry = newSimulatorDevices();
      var server = SimulatorServer(Simulation(registry));
      await server.start(port: 0);
      final port = server.port, hub = SimulatorHub(port: server.port);
      addTearDown(() async {
        await hub.dispose();
        await server.dispose();
      });
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:$port/simulator',
          headers: {
            'Origin': 'https://example.invalid',
            'X-Pressure-Simulator': '1',
          },
        ),
        throwsA(isA<WebSocketException>()),
      );
      await hub.select([
        for (final d in registry) {'id': d['device_id']},
      ]);
      await until(() => hub.peers.length == 2);
      final id = registry.first['device_id'] as String,
          boot = hub.peers[id]!.info['boot_id'];
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:$port/simulator',
          headers: {'X-Pressure-Simulator': '1'},
        ),
        throwsA(isA<WebSocketException>()),
      );
      await server.dispose();
      await until(() => hub.peers.isEmpty);
      server = SimulatorServer(Simulation(registry));
      await server.start(port: port);
      await until(() => hub.peers.length == 2);
      expect(hub.peers[id]!.info['boot_id'], isNot(boot));
    },
  );

  test(
    'Two simulated sensors use the real capture, SQLite, map and upload path',
    () async {
      const gpsEnabled = bool.fromEnvironment('HAS_GPS', defaultValue: true);
      final temp = await Directory.systemTemp.createTemp('pressure-simulator-');
      final store = await openStore(
        'simulator-test',
        file: '${temp.path}/test.sqlite',
      );
      final registry = newSimulatorDevices();
      expect(
        newSimulatorDevices().first['device_id'],
        isNot(registry.first['device_id']),
      );
      final server = SimulatorServer(Simulation(registry));
      await server.start(port: 0);
      final capture = NativeCapture(
        simulated: true,
        simulationPort: server.port,
      );
      addTearDown(() async {
        await capture.dispose();
        await server.dispose();
        await store.close();
        await temp.delete(recursive: true);
      });
      await capture.scan();
      await until(() => objects(capture.state['discovered']).length == 2);
      await capture.select([
        for (final d in registry) {'id': d['device_id']},
      ]);
      await until(() => (capture.state['channels'] as Map).length == 2);
      final a = registry[0]['device_id'] as String,
          b = registry[1]['device_id'] as String;
      final session = ids.v4();
      await capture.start(store, session, {
        'collector_id': ids.v4(),
        'rig_id': ids.v4(),
        'rig_revision': 1,
        'name': 'SIM · integration',
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'gps_enabled': gpsEnabled,
        'devices': [
          for (var i = 0; i < 2; i++)
            {
              'device_id': registry[i]['device_id'],
              'ownership_id': ids.v4(),
              'role': i == 0 ? 'A' : 'B',
              'calibration': registry[i]['calibration'],
            },
        ],
      });
      if (gpsEnabled) {
        await until(
          () async => (await records(
            store,
            session,
            'samples',
          )).any((s) => s['location'] != null),
        );
      } else {
        await until(() => capture.state['saved'] >= 20);
      }
      await capture.command('simulator', {'action': 'gps', 'enabled': false});
      final gpsOff = DateTime.now().millisecondsSinceEpoch;
      await capture.command('simulator', {
        'action': 'device',
        'device_id': a,
        'pressure_bar': 50,
      });
      await capture.command('simulator', {
        'action': 'device',
        'device_id': b,
        'sensor_error': true,
      });
      await until(() => capture.state['channels'][b]['pressure_pa'] == null);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await capture.command('simulator', {
        'action': 'device',
        'device_id': b,
        'online': false,
      });
      await until(() => capture.state['channels'][b]['connected'] == false);
      await capture.command('simulator', {
        'action': 'device',
        'device_id': b,
        'online': true,
        'sensor_error': false,
        'reboot': true,
      });
      await until(() => capture.state['channels'][b]['connected'] == true);
      await until(() => DateTime.now().millisecondsSinceEpoch - gpsOff > 3200);
      await capture.stop();
      final samples = await records(store, session, 'samples'),
          fixes = await records(store, session, 'gps_fixes');
      expect(samples.where((s) => s['device_id'] == a).length, greaterThan(10));
      expect(samples.where((s) => s['device_id'] == b).length, greaterThan(10));
      expect(
        samples
            .where((s) => s['device_id'] == b)
            .map((s) => s['boot_id'])
            .toSet(),
        hasLength(2),
      );
      expect(
        samples.any((s) => (s['flags'] as List).contains('sensor_error')),
        true,
      );
      final withoutGps = samples
          .where((s) => milliseconds(s['captured_at']) > gpsOff + 2200)
          .toList();
      expect(withoutGps, isNotEmpty);
      expect(withoutGps.every((s) => s['location'] == null), true);
      expect(withoutGps.any((s) => s['pressure_pa'] == 5000000), true);
      expect((await store.sessions()).single['end']['gaps'], isNotEmpty);
      final grid = PressureGrid(GridSpec.at(47.1, 19.3, 10), {session: fixes});
      for (final s in samples) {
        grid.add(session, s['device_id'] == a ? 'A' : 'B', s);
      }
      expect(objects(grid.finish()['cells']).isNotEmpty, gpsEnabled);
      String? lostBatch;
      var retryChecked = false;
      final uploaded = <Json>[];
      final api = Api(
        'https://service.invalid/api/v1',
        client: MockClient((r) async {
          final body = object(jsonDecode(r.body));
          if (r.url.path.endsWith('/batches')) {
            if (lostBatch == null) {
              lostBatch = r.body;
              throw const SocketException('lost response');
            }
            if (!retryChecked) {
              expect(r.body, lostBatch);
              retryChecked = true;
            }
            uploaded.addAll(objects(body['samples']));
            return http.Response(
              jsonEncode({
                'batch_id': body['batch_id'],
                'inserted':
                    objects(body['samples']).length +
                    objects(body['gps_fixes']).length +
                    objects(body['time_segments']).length,
                'duplicates': 0,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      )..account = {'id': 'test'};
      addTearDown(api.close);
      final uploader = Uploader(api, store, 'test');
      await uploader.tick(force: true);
      expect(await store.pendingCount(), samples.length);
      await uploader.tick(force: true);
      expect(retryChecked, true);
      expect(uploaded.length, samples.length);
      expect(
        uploaded.any((s) => s['location'] == null && s['pressure_pa'] != null),
        true,
      );
      expect(await store.pendingCount(), 0);
      expect((await store.sessions()).single['completed'], true);
    },
  );
}
