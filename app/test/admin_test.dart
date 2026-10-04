import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pressure_field/sync/api.dart';
import 'package:pressure_field/ui/admin.dart';

void main() {
  const secret = 'private-hardware-key-never-rendered';
  final data = [
    {'device_id': 'hps-000000000001', 'secret_hex': secret},
  ];
  XFile file(String text) => XFile.fromData(
    Uint8List.fromList(utf8.encode(text)),
    name: 'devices.simulator.json',
    mimeType: 'application/json',
  );

  testWidgets(
    'Preview precedes import, owner is shown and secrets stay hidden',
    (tester) async {
      final calls = <http.Request>[];
      final api = Api(
        'https://test.example/api/v1',
        client: MockClient((request) async {
          calls.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'device_id': 'hps-000000000001',
                    'status': 'paired',
                    'owner': {
                      'email': 'owner@example.test',
                      'account_id': 'owner-id',
                    },
                    'sensor_serial': 1,
                    'protocol_version': 2,
                  },
                ],
                'next_cursor': null,
              }),
              200,
            );
          }
          expect(jsonDecode(request.body), data);
          return http.Response(
            jsonEncode({
              'valid': true,
              'counts': {'new': 1, 'unchanged': 0, 'conflict': 0},
              'items': [],
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AdminDevicesPage(
              api,
              pickFile: () async => file(jsonEncode(data)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tulajdonos: owner@example.test'), findsOneWidget);
      final button = find.widgetWithText(FilledButton, 'Importálás');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(find.text('JSON kiválasztása és ellenőrzése'));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((r) => r.method == 'POST')
            .single
            .url
            .queryParameters['dry_run'],
        'true',
      );
      expect(find.textContaining(secret), findsNothing);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        calls
            .where((r) => r.method == 'POST')
            .last
            .url
            .queryParameters['dry_run'],
        'false',
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.textContaining('Import kész:'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(tester.takeException(), isNull);
      api.close();
    },
  );

  testWidgets(
    'Conflict and malformed file cannot be imported or expose secrets',
    (tester) async {
      var malformed = false;
      var posts = 0;
      final api = Api(
        'https://test.example/api/v1',
        client: MockClient((request) async {
          if (request.method == 'GET')
            return http.Response('{"items":[]}', 200);
          posts++;
          return http.Response(
            jsonEncode({
              'valid': false,
              'counts': {'new': 0, 'unchanged': 0, 'conflict': 1},
              'items': [
                {'device_id': 'hps-000000000001', 'status': 'conflict'},
              ],
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AdminDevicesPage(
              api,
              pickFile: () async =>
                  file(malformed ? '{"$secret":' : jsonEncode(data)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('JSON kiválasztása és ellenőrzése'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ütköző azonosító:'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Importálás'),
            )
            .onPressed,
        isNull,
      );
      malformed = true;
      await tester.tap(find.text('JSON kiválasztása és ellenőrzése'));
      await tester.pumpAndSettle();
      expect(find.text('A fájl nem érvényes JSON.'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      expect(posts, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Importálás'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      api.close();
    },
  );
}
