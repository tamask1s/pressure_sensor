import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/storage/store_api.dart';
import 'package:pressure_field/storage/store_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Eight hours of two 10 Hz channels remain complete on disk',
    () async {
      final directory = await Directory.systemTemp.createTemp('pressure-soak-'),
          path = '${directory.path}/soak.sqlite';
      var store = await openStore('soak', file: path);
      final watch = Stopwatch()..start();
      const count = 576000;
      final start = DateTime.utc(2026, 10, 3, 8).millisecondsSinceEpoch;
      try {
        await store.startSession('session', {
          'started_at': utc(start),
          'devices': [],
        });
        for (var from = 0; from < count; from += 1000) {
          await store.writeRecords('session', [
            for (var i = from; i < from + 1000; i++)
              record('samples', {
                'device_id': i.isEven ? 'hps-001122334455' : 'hps-001122334456',
                'boot_id': 'boot',
                'seq': i ~/ 2,
                'time_segment_id': 'clock',
                'uptime_ms': i ~/ 2 * 100,
                'captured_at': utc(start + i ~/ 2 * 100),
                'raw_count': 0,
                'pressure_pa': 10000000,
                'battery_mv': 3900,
                'soc_pct': 78,
                'flags': ['gps_missing'],
                'location': null,
              }),
          ]);
        }
        final written = watch.elapsedMilliseconds;
        await store.close();
        store = await openStore('soak', file: path);
        expect(
          (await store.counts('session')).values.fold(0, (sum, n) => sum + n),
          count,
        );
        var read = 0;
        await for (final page in store.records('session', 'samples')) {
          read += page.length;
        }
        expect(read, count);
        final size = await File(path).length();
        // This is an accelerated SQLite test, not a physical eight-hour BLE test.
        // ignore: avoid_print
        print(
          'SOAK: $count samples; write ${written}ms; reopen+read ${watch.elapsedMilliseconds - written}ms; SQLite $size bytes.',
        );
      } finally {
        await store.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('RUN_SOAK'),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
