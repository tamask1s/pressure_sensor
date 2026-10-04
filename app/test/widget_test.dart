import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pressure_field/controller.dart';
import 'package:pressure_field/ui/overview.dart';
import 'package:pressure_field/ui/auth.dart';
import 'package:pressure_field/main.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pressure_field/core/model.dart';

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('SCREENSHOTS')) {
      final font = FontLoader('Preview')
        ..addFont(
          File(
            'C:/Windows/Fonts/segoeui.ttf',
          ).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });
  testWidgets('Phone overview has a clear first step without sensors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppController()
      ..account = {'id': 'local', 'email': 'Helyi használat'};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OverviewPage(app, devices: () {})),
      ),
    );
    expect(find.text('Kezdj egy eszközpárral'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
  testWidgets('Login explains the scope of local measurements', (tester) async {
    final app = AppController();
    await tester.pumpWidget(MaterialApp(home: AuthPage(app)));
    expect(find.text('Belépés'), findsOneWidget);
    expect(find.text('Mérés fiók nélkül, ezen az eszközön'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
  testWidgets('Live pair fits a phone and desktop without overflow', (
    tester,
  ) async {
    final app = AppController()
      ..account = {'id': 'local', 'email': 'Helyi használat'};
    app.devices = [
      for (final n in [1, 2])
        {
          'id': 'hps-00000000000$n',
          'name': '$n. érzékelő',
          'calibration': {'verified': true},
        },
    ];
    app.rig = {
      'id': 'pair',
      'name': '1. traktor',
      'device_a_id': app.devices[0]['id'],
      'device_b_id': app.devices[1]['id'],
    };
    app.rigs = [app.rig!];
    final at = DateTime.now().millisecondsSinceEpoch;
    app.capture.state['channels'] = {
      for (var n = 0; n < 2; n++)
        app.devices[n]['id']: {
          'connected': true,
          'stale': false,
          'pressure_pa': 12500000 + n * 200000,
          'soc_pct': 78 + n,
          'flags': 7,
          'chart': <Json>[
            for (var t = 0; t < 600; t++)
              {
                'at': at - 60000 + t * 100,
                'pa': 10000000 + n * 200000 + t % 100 * 40000,
              },
          ],
        },
    };
    final boundary = GlobalKey();
    for (final size in [const Size(360, 800), const Size(1200, 850)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: pressureTheme(
              fontFamily: const bool.fromEnvironment('SCREENSHOTS')
                  ? 'Preview'
                  : null,
            ),
            home: Home(app),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('SCREENSHOTS')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../.tools/ui-${size.width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
