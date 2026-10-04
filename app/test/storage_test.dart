import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/measurement/capture_native.dart';
import 'package:pressure_field/storage/store_native.dart';
import 'package:pressure_field/storage/store_api.dart';
import 'package:pressure_field/sync/api.dart';
import 'package:pressure_field/sync/uploader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Store store;
  late String path;
  final segment = {
    'id': 'clock',
    'device_id': 'hps-001122334455',
    'boot_id': 'boot',
    'uptime_anchor_ms': 0,
    'utc_anchor': utc(0),
    'uncertainty_ms': 10,
    'source': 'phone',
  };
  Json sample(int seq) => {
    'device_id': 'hps-001122334455',
    'boot_id': 'boot',
    'seq': seq,
    'time_segment_id': 'clock',
    'uptime_ms': seq * 100,
    'captured_at': utc(seq * 100),
    'pressure_pa': 0,
    'raw_count': -16000,
    'battery_mv': null,
    'soc_pct': null,
    'flags': ['gps_missing'],
    'location': null,
  };
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pressure-test-');
    path = '${temp.path}/account.sqlite';
    store = await openStore('test', file: path);
    await store.startSession('s', {
      'name': 'test',
      'devices': [],
      'started_at': utc(0),
    });
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });
  test('Pending GPS and immutable batches survive a database reopen', () async {
    await store.writeRecords('s', [
      record('time_segments', segment),
      record('samples', sample(1), ready: false),
    ]);
    expect(await store.pendingCount(), 1);
    expect(await store.pendingSamples('s'), hasLength(1));
    await store.finalizeSamples([
      {'id': 'hps-001122334455/boot/1', 'data': sample(1)},
    ]);
    final first = await store.nextBatch('s');
    expect(first!['samples'], hasLength(1));
    expect(first['time_segments'], hasLength(1));
    await store.close();
    store = await openStore('test', file: path);
    expect(await store.nextBatch('s'), first);
    await store.acknowledge(first['batch_id']);
    expect(await store.pendingCount(), 0);
    expect(await store.nextBatch('s'), isNull);
  });
  test(
    'Duplicate sample accepts identical replay and rejects changed data or another session',
    () async {
      await store.writeRecords('s', [
        record('time_segments', segment),
        record('samples', sample(1)),
      ]);
      await store.writeRecords('s', [record('samples', sample(1))]);
      expect((await store.counts('s')).values.single, 1);
      await expectLater(
        store.writeRecords('s', [
          record('samples', {...sample(1), 'pressure_pa': 1}),
        ]),
        throwsFormatException,
      );
      await store.startSession('other', {'started_at': utc(0)});
      await expectLater(
        store.writeRecords('other', [record('samples', sample(1))]),
        throwsFormatException,
      );
    },
  );
  test(
    'GPS-less upload retains timestamp and retries the exact batch after response loss',
    () async {
      await store.writeRecords('s', [
        record('time_segments', segment),
        record('samples', sample(1)),
      ]);
      await store.finishSession('s', {
        'status': 'completed',
        'ended_at': utc(1000),
        'expected_samples_by_device': {'hps-001122334455': 1},
        'gaps': [],
      });
      String? first;
      var batches = 0, completions = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/batches')) {
          batches++;
          first ??= request.body;
          expect(request.body, first);
          final b = object(jsonDecode(request.body));
          expect(b['samples'][0]['location'], isNull);
          expect(b['samples'][0]['captured_at'], utc(100));
          if (batches == 1) throw const SocketException('lost response');
          return http.Response(
            jsonEncode({
              'batch_id': b['batch_id'],
              'inserted': 0,
              'duplicates': 2,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/complete')) completions++;
        return http.Response('{}', 200);
      });
      final api = Api('https://service.invalid/api/v1', client: client)
        ..account = {'id': 'test'};
      final uploader = Uploader(api, store, 'test');
      await uploader.tick(force: true);
      expect(await store.pendingCount(), 1);
      expect(completions, 0);
      await uploader.tick(force: true);
      expect(batches, 2);
      expect(completions, 1);
      expect(await store.pendingCount(), 0);
      expect((await store.sessions()).single['completed'], true);
      api.close();
    },
  );
  test('An uploader never sends another account database', () async {
    var requests = 0;
    final api = Api(
      'https://service.invalid/api/v1',
      client: MockClient((r) async {
        requests++;
        return http.Response('{}', 200);
      }),
    )..account = {'id': 'other'};
    await Uploader(api, store, 'test').tick(force: true);
    expect(requests, 0);
    api.close();
  });
  test(
    'Crash recovery closes a session and keeps GPS-less pressure uploadable',
    () async {
      await store.writeRecords('s', [
        record('time_segments', segment),
        record('samples', sample(1), ready: false),
      ]);
      await store.close();
      store = await openStore('test', file: path);
      final capture = NativeCapture();
      await capture.recover(store);
      expect(await store.pendingSamples('s'), isEmpty);
      final recovered = (await store.sessions()).single;
      expect(recovered['end']['status'], 'interrupted');
      expect(
        recovered['end']['expected_samples_by_device']['hps-001122334455'],
        1,
      );
      final batch = await store.nextBatch('s');
      expect(batch!['samples'][0]['pressure_pa'], 0);
      expect(batch['samples'][0]['location'], isNull);
      expect(batch['samples'][0]['captured_at'], utc(100));
      await capture.dispose();
    },
  );
}
