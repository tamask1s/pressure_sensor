import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pressure_field/controller.dart';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/sync/api.dart';
import 'package:pressure_field/ui/history.dart';

void main() {
  final start = DateTime.utc(2026, 10, 4).millisecondsSinceEpoch;
  Json session(Duration duration) => {
    'id': 'recorded-session',
    'start': {
      'name': 'SIM · Windows service integration',
      'started_at': utc(start),
      'devices': [
        {'device_id': 'hps-000000000001', 'role': 'A'},
        {'device_id': 'hps-000000000002', 'role': 'B'},
      ],
    },
    'end': {'ended_at': utc(start + duration.inMilliseconds)},
  };
  AppController controller(List<http.Request> requests) => AppController(
    api: Api(
      'https://test.example/api/v1',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'items': [
              for (final id in ['hps-000000000001', 'hps-000000000002'])
                {
                  'device_id': id,
                  'captured_at': utc(start),
                  'mean_pa': 10000000,
                  'min_pa': 9000000,
                  'max_pa': 11000000,
                },
            ],
          }),
          200,
        );
      }),
    ),
  );

  testWidgets('Recorded short session opens its pressure chart on the web', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final app = controller(requests);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionPage(
          app,
          session(const Duration(seconds: 33)),
          showMap: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(
      requests.single.url.path,
      '/api/v1/sessions/recorded-session/series',
    );
    expect(requests.single.url.queryParameters['bucket_ms'], '100');
    expect(find.text('Nyomás · átlag és min/max tartomány'), findsOneWidget);
    expect(find.textContaining('Invalid argument'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  test(
    'Long recordings request service-compatible buckets and device filter',
    () async {
      final requests = <http.Request>[];
      final app = controller(requests);
      for (final duration in [
        const Duration(hours: 8),
        const Duration(days: 1000),
      ]) {
        final points = await app.series(
          session(duration),
          deviceId: 'hps-000000000001',
        );
        final query = requests.last.url.queryParameters;
        final bucket = int.parse(query['bucket_ms']!);
        expect(bucket, inInclusiveRange(100, 86400000));
        expect(duration.inMilliseconds / bucket, lessThanOrEqualTo(2500));
        expect(query['device_id'], 'hps-000000000001');
        expect(points.first['pa'], 10000000);
        expect(points.first['at'], start);
      }
      app.dispose();
    },
  );
}
