import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../controller.dart';
import '../core/model.dart';
import 'common.dart';

class OverviewPage extends StatefulWidget {
  final AppController app;
  final VoidCallback devices;
  const OverviewPage(this.app, {super.key, required this.devices});
  @override
  State<OverviewPage> createState() => _OverviewState();
}

class _OverviewState extends State<OverviewPage> {
  bool busy = false;
  AppController get app => widget.app;
  Future<void> toggle() async {
    if (busy) return;
    if (app.recording) {
      setState(() => busy = true);
      await guard(context, app.stop);
      if (mounted) setState(() => busy = false);
      return;
    }
    final name = await askText(
      context,
      'Új mérés',
      label: 'Mérés neve',
      initial: app.rig?['name'] as String? ?? '',
      help:
          'A helyi napló azonnal indul. A GPS automatikus; a feltöltés internet nélkül később folytatódik.',
    );
    if (name == null || !mounted) return;
    setState(() => busy = true);
    await guard(context, () => app.start(name));
    if (mounted) setState(() => busy = false);
  }

  Widget deviceCard(String role) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    final id = app.rig?[role == 'A' ? 'device_a_id' : 'device_b_id'] as String?;
    final d = id == null ? <String, dynamic>{} : app.device(id),
        native = app.channels[id],
        p = d['presence'] as Map?;
    final c = kIsWeb ? p : native;
    final fresh = kIsWeb
        ? app.presenceFresh(p)
        : (c?['connected'] == true && c?['stale'] == false);
    final status = fresh
        ? (kIsWeb ? 'Friss állapotjelzés' : 'Élő adat')
        : (kIsWeb
              ? (p?['state'] == 'collector_online_device_stale'
                    ? 'Gyűjtő elérhető, adat késik'
                    : 'Utoljára látva')
              : c?['connected'] == true
              ? 'Várakozás adatra'
              : 'Nincs kapcsolat');
    return Panel(
      padding: EdgeInsets.all(compact ? 14 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: compact ? 16 : 20,
                backgroundColor: role == 'A' ? green : blue,
                foregroundColor: Colors.white,
                child: Text(role),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  d['name'] as String? ?? '$role érzékelő',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (!kIsWeb && id != null)
                PopupMenuButton<String>(
                  tooltip: 'Eszköz műveletei',
                  onSelected: (v) => guard(context, () async {
                    if (v == 'identify') {
                      await app.capture.command(id, {'op': 'identify'});
                    }
                    if (v == 'disconnect') await app.capture.disconnect(id);
                    if (v == 'connect') await app.connectRig(app.rig!);
                    if (v == 'sd') {
                      await app.capture.command(id, {
                        'op': 'sd',
                        'enabled': ((c?['flags'] as int? ?? 0) & 4) == 0,
                      });
                    }
                  }),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'identify',
                      child: Text('LED-es azonosítás'),
                    ),
                    const PopupMenuItem(
                      value: 'sd',
                      child: Text('SD-napló ki / be'),
                    ),
                    if (!app.recording)
                      const PopupMenuItem(
                        value: 'connect',
                        child: Text('Újracsatlakozás'),
                      ),
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: Text('Kapcsolat bontása'),
                    ),
                  ],
                ),
            ],
          ),
          SizedBox(height: compact ? 6 : 18),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 8,
            children: [
              Text(
                fresh ? bar(c?['pressure_pa']) : '—',
                style: TextStyle(
                  fontSize: compact ? 40 : 48,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  color: role == 'A' ? green : blue,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text('bar', style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 18),
          Row(
            children: [
              Icon(
                fresh ? Icons.circle : Icons.circle_outlined,
                color: fresh ? green : Colors.grey,
                size: 11,
              ),
              const SizedBox(width: 7),
              Expanded(child: Text(status)),
              const Icon(Icons.battery_std, size: 18),
              Text(c?['soc_pct'] == null ? ' —' : ' ${c!['soc_pct']}%'),
            ],
          ),
          if (id != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '$id${kIsWeb && p?['last_seen_at'] != null ? ' · ${date(p!['last_seen_at'])}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (kIsWeb && p?['observed_at'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Állapot ideje: ${date(p!['observed_at'])}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (!kIsWeb && c != null && ((c['flags'] as int? ?? 0) & 8) != 0)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'SD-kártyahiba · az app külön rögzít',
                style: TextStyle(color: Colors.brown),
              ),
            ),
          if (d['calibration']?['verified'] == false)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A nyomástartomány ellenőrzése szükséges.',
                style: TextStyle(color: Colors.brown, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 20,
          runSpacing: 16,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kIsWeb ? 'A földeken, most' : 'Minden mérés számít.',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  kIsWeb
                      ? 'Az alkalmazások által jelentett legutóbbi állapot.'
                      : 'Élő nyomásadatok és automatikus helyi napló.',
                ),
              ],
            ),
            if (!kIsWeb)
              FilledButton.icon(
                onPressed: busy || app.rig == null ? null : toggle,
                style: FilledButton.styleFrom(
                  backgroundColor: app.recording
                      ? const Color(0xff9c4139)
                      : green,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
                ),
                icon: Icon(
                  app.recording
                      ? Icons.stop_rounded
                      : Icons.fiber_manual_record,
                ),
                label: Text(
                  busy
                      ? 'Egy pillanat…'
                      : app.recording
                      ? 'Mérés leállítása'
                      : 'Mérés indítása',
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        if (app.rigs.isEmpty)
          Empty(
            Icons.sensors,
            'Kezdj egy eszközpárral',
            'Add hozzá a két készüléket, majd hozz létre belőlük egy párt.',
            action: FilledButton(
              onPressed: widget.devices,
              child: const Text('Eszközök megnyitása'),
            ),
          )
        else ...[
          DropdownButtonFormField<String>(
            initialValue: app.rig?['id'] as String?,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Aktív eszközpár',
              prefixIcon: Icon(Icons.agriculture_outlined),
            ),
            items: app.rigs
                .map(
                  (r) => DropdownMenuItem(
                    value: r['id'] as String,
                    child: Text(r['name'] as String),
                  ),
                )
                .toList(),
            onChanged: app.recording
                ? null
                : (id) {
                    final r = app.rigs.firstWhere((r) => r['id'] == id);
                    if (kIsWeb) {
                      app.rig = r;
                      app.changed();
                    } else {
                      guard(context, () => app.connectRig(r));
                    }
                  },
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 620
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: deviceCard('A')),
                      const SizedBox(width: 20),
                      Expanded(child: deviceCard('B')),
                    ],
                  )
                : Column(
                    children: [
                      deviceCard('A'),
                      const SizedBox(height: 16),
                      deviceCard('B'),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          if (!kIsWeb)
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Az utolsó 60 másodperc',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  PressureChart([
                    for (final key in ['device_a_id', 'device_b_id'])
                      objects(app.channels[app.rig?[key]]?['chart']),
                  ]),
                ],
              ),
            ),
        ],
        const SizedBox(height: 20),
        if (!kIsWeb)
          Hint(
            '${app.capture.state['paused_due_to_error'] == true
                ? 'A rögzítés hiba miatt megállt'
                : app.recording
                ? 'Rögzítés folyamatban · ${app.capture.state['saved']} minta'
                : 'A rögzítés a Mérés indítása gombbal kezdődik.'}\n${hasGps ? app.capture.state['gps'] : 'GPS nélküli kiadás'}',
            icon: app.recording
                ? Icons.radio_button_checked
                : Icons.info_outline,
          ),
        if (app.capture.state['error'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Hint(app.capture.state['error'] as String, warning: true),
          ),
        if (!kIsWeb)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              children: [
                const Icon(Icons.cloud_upload_outlined, color: green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${app.syncStatus.isEmpty ? 'A helyi napló készen áll' : app.syncStatus}${!app.local ? ' · ${app.pending} minta vár feltöltésre' : ''}',
                  ),
                ),
                if (!app.local)
                  IconButton(
                    tooltip: 'Feltöltés most',
                    onPressed: () =>
                        guard(context, () => app.synchronize(force: true)),
                    icon: const Icon(Icons.sync),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        const Text(
          'A kijelzett érték nyomás. Talajtömörségi osztályozáshoz külön terepi kalibráció szükséges.',
          style: TextStyle(fontSize: 12, color: Color(0xff64776e)),
        ),
      ],
    );
  }
}
