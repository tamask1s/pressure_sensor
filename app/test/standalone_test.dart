import 'dart:io';
import 'package:flutter/material.dart' hide Simulation;
import 'package:flutter_test/flutter_test.dart';
import 'package:pressure_field/controller.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/platform/recording.dart';
import 'package:pressure_field/simulator/engine.dart';
import 'package:pressure_field/simulator/server.dart';
import 'package:pressure_field/storage/store_native.dart';
import 'package:pressure_field/ui/standalone.dart';
import 'simulator_test.dart' show until, records;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Independent logs share a connection; stopping A keeps B recording',
    () async {
      HttpOverrides.global = null;
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(nativeRecording, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      final temp = await Directory.systemTemp.createTemp(
        'pressure-independent-',
      );
      final store = await openStore(
        'standalone-test',
        file: '${temp.path}/test.sqlite',
      );
      final server = SimulatorServer(Simulation(newSimulatorDevices()));
      await server.start(port: 0);
      final app =
          AppController(
              standalone: true,
              simulated: true,
              simulationPort: server.port,
            )
            ..account = {'id': 'local', 'email': 'Helyi használat'}
            ..store = store;
      addTearDown(() async {
        for (final id in app.recorders.keys.toList()) {
          await app.stopDevice(id);
        }
        await app.logout();
        app.dispose();
        await server.dispose();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          nativeRecording,
          null,
        );
        await temp.delete(recursive: true);
      });
      await app.prepareSimulation();
      expect(app.rigs, isEmpty);
      final a = app.devices[0]['id'] as String,
          b = app.devices[1]['id'] as String;
      await app.startDevice(a);
      final sessionA = app.recorders[a]!.state['session_id'] as String;
      await app.startDevice(b);
      final sessionB = app.recorders[b]!.state['session_id'] as String;
      await until(
        () =>
            app.recorders[a]!.state['saved'] >= 5 &&
            app.recorders[b]!.state['saved'] >= 5,
      );
      await app.capture.command(a, {'op': 'sd', 'enabled': true});
      await until(() => (app.channels[a]!['flags'] as int) & 4 != 0);
      await app.stopDevice(a);
      expect(app.deviceRecording(b), true);
      expect(calls.where((c) => c == 'stop'), isEmpty);
      final bSaved = app.recorders[b]!.state['saved'] as int;
      // A can lose power without disturbing B's connection or log.
      await app.capture.command('simulator', {
        'action': 'device',
        'device_id': a,
        'online': false,
      });
      await until(() => app.recorders[b]!.state['saved'] > bSaved + 5);
      await app.capture.command('simulator', {
        'action': 'device',
        'device_id': b,
        'online': false,
      });
      await until(() => app.channels[b]?['connected'] == false);
      await app.capture.command('simulator', {
        'action': 'device',
        'device_id': b,
        'online': true,
        'reboot': true,
      });
      await until(() => app.channels[b]?['connected'] == true);
      await until(() => app.recorders[b]!.state['saved'] > bSaved + 10);
      await app.stopDevice(b);
      expect(calls.where((c) => c == 'stop'), hasLength(1));
      expect(calls.where((c) => c == 'start'), hasLength(1));
      expect(app.recording, false);
      for (final pair in [(sessionA, a), (sessionB, b)]) {
        final rows = await records(store, pair.$1, 'samples');
        expect(rows, isNotEmpty);
        expect(
          rows.every((r) => r['device_id'] == pair.$2 && r['location'] == null),
          true,
        );
        expect(
          rows.every((r) => (r['flags'] as List).contains('gps_disabled')),
          true,
        );
        final segments = await records(store, pair.$1, 'time_segments');
        expect(
          segments.every(
            (s) => s['device_id'] == null || s['device_id'] == pair.$2,
          ),
          true,
        );
      }
      expect(
        (await records(
          store,
          sessionB,
          'samples',
        )).map((r) => r['boot_id']).toSet(),
        hasLength(2),
      );
      final sessions = await store.sessions();
      expect(sessions.every((s) => s['end']['status'] == 'completed'), true);
      expect(
        sessions.firstWhere((s) => s['id'] == sessionB)['end']['gaps'],
        isNotEmpty,
      );
    },
  );

  testWidgets(
    'Standalone phone UI has independent logging and no account or map',
    (tester) async {
      tester.view.physicalSize = const Size(360, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AppController(standalone: true)..account = {'id': 'local'};
      app.devices = [
        {'id': 'hps-000000000001', 'name': 'Bal érzékelő'},
      ];
      app.capture.state['channels'] = <String, Json>{
        'hps-000000000001': {
          'connected': true,
          'stale': false,
          'pressure_pa': 5000000,
          'flags': 1,
          'chart': <Json>[],
        },
      };
      await tester.pumpWidget(MaterialApp(home: StandaloneHome(app)));
      expect(find.text('Napló indítása'), findsOneWidget);
      expect(find.text('SD-kártya naplózása'), findsOneWidget);
      expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
      expect(find.textContaining('Térkép'), findsNothing);
      expect(find.textContaining('Belépés'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
}
