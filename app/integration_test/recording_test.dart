import 'dart:io';
import 'package:flutter/material.dart' hide Simulation;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pressure_field/controller.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/simulator/engine.dart';
import 'package:pressure_field/simulator/server.dart';
import 'package:pressure_field/storage/store_native.dart';

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Recording did not progress');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android saves independent logs and reopens their samples', (
    tester,
  ) async {
    expect(Platform.isAndroid, true);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Naplózási próba'))),
    );
    final temp = await Directory.systemTemp.createTemp('pressure-android-');
    final file = '${temp.path}/measurements.sqlite';
    // Uses the real Android SQLite plugin, not the desktop FFI implementation.
    final store = await openStore('android-test', file: file);
    final server = SimulatorServer(Simulation(newSimulatorDevices()));
    await server.start(port: 0);
    final app =
        AppController(
            standalone: true,
            simulated: true,
            simulationPort: server.port,
          )
          ..account = {'id': 'local'}
          ..store = store;
    addTearDown(() async {
      for (final id in app.recorders.keys.toList()) {
        await app.stopDevice(id);
      }
      await app.logout();
      app.dispose();
      await server.dispose();
      await temp.delete(recursive: true);
    });
    expect(
      (await (store as SqlStore).db.rawQuery('PRAGMA journal_mode')).single,
      {'journal_mode': 'wal'},
    );
    expect(
      (await store.db.rawQuery('PRAGMA foreign_keys')).single['foreign_keys'],
      1,
    );
    await app.prepareSimulation();
    final a = app.devices[0]['id'] as String;
    final b = app.devices[1]['id'] as String;
    // Notification/Bluetooth permissions are granted by CI before launching.
    // Both logs use the real Android foreground service and wake lock.
    await app.startDevice(a);
    final sessionA = app.recorders[a]!.state['session_id'] as String;
    await until(() => app.recorders[a]!.state['saved'] >= 5);
    await app.startDevice(b);
    final sessionB = app.recorders[b]!.state['session_id'] as String;
    await until(() => app.recorders[b]!.state['saved'] >= 5);
    await app.stopDevice(a);
    final before = app.recorders[b]!.state['saved'] as int;
    await until(() => app.recorders[b]!.state['saved'] >= before + 5);
    await app.stopDevice(b);
    expect(app.recording, false);

    final countsA = await store.counts(sessionA);
    final countsB = await store.counts(sessionB);
    expect(countsA.keys, [a]);
    expect(countsB.keys, [b]);
    await store.close();
    final reopened = await openStore('android-test', file: file);
    app.store = reopened;
    expect(await reopened.counts(sessionA), countsA);
    expect(await reopened.counts(sessionB), countsB);
    expect(
      (await reopened.sessions()).every(
        (s) => s['end']['status'] == 'completed',
      ),
      true,
    );
    await for (final rows in reopened.records(sessionA, 'samples')) {
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row['device_id'], a);
        expect(row['location'], isNull);
        expect(milliseconds(row['captured_at']), greaterThan(0));
      }
    }
  });
}
