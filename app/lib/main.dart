import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'controller.dart';
import 'core/model.dart';
import 'ui/common.dart';
import 'ui/auth.dart';
import 'ui/overview.dart';
import 'ui/devices.dart';
import 'ui/history.dart';
import 'ui/map.dart';
import 'ui/admin.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final simulated =
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows &&
      arguments.contains('--simulator');
  final port =
      int.tryParse(
        arguments
                .where((a) => a.startsWith('--simulator-port='))
                .firstOrNull
                ?.split('=')
                .last ??
            '',
      ) ??
      47832;
  runApp(PressureApp(simulated: simulated, simulationPort: port));
}

ThemeData pressureTheme({String? fontFamily}) => ThemeData(
  useMaterial3: true,
  fontFamily: fontFamily,
  colorScheme: ColorScheme.fromSeed(
    seedColor: green,
    surface: const Color(0xfffbfcf9),
  ),
  scaffoldBackgroundColor: const Color(0xfff3f5ef),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xfff3f5ef),
    foregroundColor: ink,
    centerTitle: false,
  ),
  cardTheme: CardThemeData(
    elevation: 0,
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xffe0e7dd)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xffcbd8ce)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  textTheme: const TextTheme(bodyMedium: TextStyle(height: 1.45, color: ink)),
);

class PressureApp extends StatefulWidget {
  final bool simulated;
  final int simulationPort;
  const PressureApp({
    super.key,
    this.simulated = false,
    this.simulationPort = 47832,
  });
  @override
  State<PressureApp> createState() => _AppState();
}

class _AppState extends State<PressureApp> {
  late final app = AppController(
    simulated: widget.simulated,
    simulationPort: widget.simulationPort,
  );
  @override
  void initState() {
    super.initState();
    unawaited(app.init());
  }

  @override
  void dispose() {
    app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Talajnyomás',
    debugShowCheckedModeBanner: false,
    theme: pressureTheme(),
    home: ListenableBuilder(
      listenable: app,
      builder: (context, _) => !app.ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : !app.signedIn
          ? AuthPage(app)
          : Home(app),
    ),
  );
}

class Home extends StatefulWidget {
  final AppController app;
  const Home(this.app, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int index = 0;
  Json? mapSession;
  AppController get app => widget.app;
  void select(int i) => setState(() {
    index = i;
    if (i == 1) mapSession = null;
  });
  Future<void> account() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fiók'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(app.account!['email']),
              const SizedBox(height: 8),
              Text(
                app.local ? 'Helyi mód · csak ezen az eszközön' : app.api.base,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 20),
              if (app.recording)
                const Hint('A fiókműveletekhez előbb állítsd le a mérést.'),
              if (!app.local)
                TextButton(
                  onPressed: app.recording
                      ? null
                      : () async {
                          final password = await askText(
                            context,
                            'Fiók végleges törlése',
                            label: 'Jelszó',
                            secret: true,
                            help:
                                'A service-ben tárolt összes saját adat és eszköz-hozzárendelés törlődik. A telefon helyi példányai megmaradnak.',
                          );
                          if (password == null || !context.mounted) return;
                          await guard(context, () async {
                            await app.deleteAccount(password);
                            if (context.mounted) Navigator.pop(context);
                          });
                        },
                  child: const Text(
                    'Fiók törlése',
                    style: TextStyle(color: Colors.brown),
                  ),
                ),
              FilledButton(
                onPressed: app.recording
                    ? null
                    : () => guard(context, () async {
                        await app.logout();
                        if (context.mounted) Navigator.pop(context);
                      }),
                child: Text(
                  app.local ? 'Vissza a belépéshez' : 'Kijelentkezés',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Bezárás'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final admin = kIsWeb && app.account?['is_admin'] == true;
    if (!admin && index == 4) index = 0;
    final destinations = [
      (Icons.speed, kIsWeb ? 'Áttekintés' : 'Élő mérés'),
      (Icons.map_outlined, 'Térkép'),
      (Icons.history, 'Mérések'),
      (Icons.sensors, 'Eszközök'),
      if (admin) (Icons.inventory_2_outlined, 'Admin'),
    ];
    final page = switch (index) {
      0 => OverviewPage(app, devices: () => select(3)),
      1 => MapPage(
        app,
        key: ValueKey(mapSession?['id'] ?? 'all'),
        session: mapSession,
      ),
      2 => HistoryPage(
        app,
        showMap: (s) => setState(() {
          mapSession = s;
          index = 1;
        }),
      ),
      4 => AdminDevicesPage(app.api, key: ValueKey(app.account?['id'])),
      _ => DevicesPage(app),
    };
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.landscape_rounded, color: green),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                app.simulated ? 'Talajnyomás · SZIMULÁTOR' : 'Talajnyomás',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: [
          if (app.recording)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Chip(
                avatar: Icon(
                  Icons.fiber_manual_record,
                  size: 14,
                  color: Colors.red,
                ),
                label: Text('Rögzítés'),
              ),
            ),
          IconButton(
            onPressed: account,
            tooltip: app.local ? 'Helyi mód' : app.account!['email'],
            icon: const Icon(Icons.account_circle_outlined),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            if (wide) ...[
              NavigationRail(
                selectedIndex: index,
                onDestinationSelected: select,
                labelType: NavigationRailLabelType.all,
                backgroundColor: const Color(0xfff3f5ef),
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: Icon(d.$1),
                      label: Text(d.$2),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(child: page),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: select,
              destinations: [
                for (final d in destinations)
                  NavigationDestination(icon: Icon(d.$1), label: d.$2),
              ],
            ),
    );
  }
}
