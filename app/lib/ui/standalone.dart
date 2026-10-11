import 'package:flutter/material.dart';
import '../controller.dart';
import '../core/model.dart';
import 'common.dart';
import 'devices.dart';
import 'history.dart';
import 'simulator.dart';

class StandaloneHome extends StatefulWidget {
  final AppController app;
  const StandaloneHome(this.app, {super.key});
  @override
  State<StandaloneHome> createState() => _StandaloneState();
}

class _StandaloneState extends State<StandaloneHome> {
  int page = 0;
  AppController get app => widget.app;
  Future<void> add() => guard(context, () async {
    await app.capture.scan();
    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) => AddDeviceDialog(app),
      );
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(app.simulated ? 'Talajnyomás · SZIMULÁTOR' : 'Talajnyomás'),
    ),
    body: SafeArea(
      child: page == 1
          ? HistoryPage(app)
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Eszközök',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Élő nyomásmérés. Minden készülék külön naplózható.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: add,
                      icon: const Icon(Icons.add),
                      label: const Text('Eszköz csatlakoztatása'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => guard(context, app.reconnectDevices),
                      icon: const Icon(Icons.bluetooth),
                      label: const Text('Újracsatlakozás'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (app.simulated) SimulatorPanel(app),
                if (app.message != null) Hint(app.message!, warning: true),
                if (app.capture.state['error'] != null)
                  Hint(app.capture.state['error'] as String, warning: true),
                if (app.devices.isEmpty)
                  const Empty(
                    Icons.sensors,
                    'Csatlakoztasd az első készüléket',
                    'A Bluetooth-gombot tartsd nyomva 1,5 másodpercig. A párosításhoz a címkén lévő PIN szükséges.',
                  ),
                for (final d in app.devices)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _DeviceCard(app, d, key: ValueKey(d['id'])),
                  ),
                const SizedBox(height: 16),
                const Text(
                  'A kijelzett érték nyomás. Talajtömörségi osztályozáshoz terepi kalibráció szükséges.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: page,
      onDestinationSelected: (value) => setState(() => page = value),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.sensors), label: 'Eszközök'),
        NavigationDestination(icon: Icon(Icons.history), label: 'Mérések'),
      ],
    ),
  );
}

class _DeviceCard extends StatefulWidget {
  final AppController app;
  final Json device;
  const _DeviceCard(this.app, this.device, {super.key});
  @override
  State<_DeviceCard> createState() => _DeviceState();
}

class _DeviceState extends State<_DeviceCard> {
  bool busy = false;
  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    await guard(context, action);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app, d = widget.device, id = d['id'] as String;
    final c = app.channels[id], log = app.recorders[id]?.state;
    final connected = c?['connected'] == true,
        fresh = connected && c?['stale'] == false;
    final flags = c?['flags'] as int? ?? 0, recording = app.deviceRecording(id);
    final blocked = busy || app.deviceBusy(id);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  d['name'] as String? ?? id,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Átnevezés',
                icon: const Icon(Icons.edit_outlined),
                onPressed: blocked
                    ? null
                    : () => act(() async {
                        final name = await askText(
                          context,
                          'Készülék neve',
                          initial: d['name'] as String? ?? '',
                        );
                        if (name != null) await app.rename(id, name);
                      }),
              ),
            ],
          ),
          Text(id, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Text(
            '${fresh ? bar(c?['pressure_pa']) : '—'} bar',
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w600,
              color: green,
            ),
          ),
          Text(
            '${fresh
                ? 'Élő adat'
                : connected
                ? 'Adatra vár'
                : 'Nincs kapcsolat · újracsatlakozás'} · Akkumulátor: ${c?['soc_pct'] ?? '—'}%',
          ),
          const SizedBox(height: 12),
          PressureChart([objects(c?['chart'])]),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: blocked || (!recording && !connected)
                    ? null
                    : () => act(
                        () => recording
                            ? app.stopDevice(id)
                            : app.startDevice(id),
                      ),
                icon: Icon(recording ? Icons.stop : Icons.fiber_manual_record),
                label: Text(recording ? 'Napló leállítása' : 'Napló indítása'),
                style: recording
                    ? FilledButton.styleFrom(backgroundColor: Colors.brown)
                    : null,
              ),
              TextButton.icon(
                onPressed: blocked || !connected
                    ? null
                    : () => act(() async {
                        await app.capture.command(id, {'op': 'identify'});
                      }),
                icon: const Icon(Icons.lightbulb_outline),
                label: const Text('Azonosítás'),
              ),
              TextButton(
                onPressed: blocked || recording || !connected
                    ? null
                    : () => act(() => app.capture.disconnect(id)),
                child: const Text('Kapcsolat bontása'),
              ),
            ],
          ),
          Text(
            recording
                ? 'Helyi napló · ${log?['saved'] ?? 0} minta'
                : 'Helyi mentés a Napló indítása gombbal.',
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('SD-kártya naplózása'),
            subtitle: Text(
              flags & 8 != 0
                  ? 'SD-hiba · a helyi napló ettől független'
                  : flags & 4 != 0
                  ? 'Rögzítés az eszköz SD-kártyájára'
                  : 'Kikapcsolva',
            ),
            value: flags & 12 != 0,
            onChanged: blocked || !fresh
                ? null
                : (enabled) => act(() async {
                    await app.capture.command(id, {
                      'op': 'sd',
                      'enabled': enabled,
                    });
                  }),
          ),
          if (flags & 32 != 0)
            const Hint(
              'Az érzékelő nem ad érvényes nyomásadatot.',
              warning: true,
            ),
          if (flags & 64 != 0)
            const Hint('Szimulált szenzoradat · hardverteszt', warning: true),
          if ((c?['missed'] as int? ?? 0) > 0)
            Text(
              'Hiányzó Bluetooth-minták: ${c!['missed']}. A napló jelöli a kimaradásokat.',
            ),
          if (log?['error'] != null)
            Hint(log!['error'] as String, warning: true),
        ],
      ),
    );
  }
}
