import 'package:flutter/material.dart';
import '../controller.dart';
import '../core/model.dart';
import '../platform/export.dart';
import 'common.dart';

class HistoryPage extends StatefulWidget {
  final AppController app;
  final void Function(Json) showMap;
  const HistoryPage(this.app, {super.key, required this.showMap});
  @override
  State<HistoryPage> createState() => _HistoryState();
}

class _HistoryState extends State<HistoryPage> {
  String? device;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  Future<void> refresh() async {
    setState(() => loading = true);
    await guard(context, widget.app.loadHistory);
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app,
        sessions = app.history
            .where(
              (s) =>
                  device == null ||
                  objects(
                    s['start']['devices'],
                  ).any((d) => d['device_id'] == device),
            )
            .toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Korábbi mérések',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            IconButton(
              tooltip: 'Frissítés',
              onPressed: loading ? null : refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue: device ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Készülék'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Minden készülék')),
            for (final d in app.devices)
              DropdownMenuItem(
                value: d['id'] as String,
                child: Text(d['name'] as String? ?? d['id']),
              ),
          ],
          onChanged: (v) => setState(() => device = v == '' ? null : v),
        ),
        const SizedBox(height: 20),
        if (loading) const LinearProgressIndicator(),
        if (sessions.isEmpty)
          const Empty(
            Icons.history,
            'Még nincs rögzített mérés',
            'Az elindított mérések itt maradnak, GPS és internet nélkül is.',
          ),
        for (final s in sessions)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Panel(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  s['end'] == null
                      ? Icons.radio_button_checked
                      : Icons.show_chart,
                  color: green,
                ),
                title: Text(s['start']['name'] as String? ?? 'Mérés'),
                subtitle: Text(
                  '${date(s['start']['started_at'])} · ${s['end'] == null
                      ? 'folyamatban'
                      : s['end']['status'] == 'interrupted'
                      ? 'megszakadt'
                      : 'lezárt'}\n${s['completed'] == true
                      ? 'Felhőben elérhető'
                      : app.local
                      ? 'Csak ezen az eszközön'
                      : 'Helyben mentve · szinkronizálás folyamatban'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SessionPage(
                      app,
                      s,
                      device: device,
                      showMap: () => widget.showMap(s),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SessionPage extends StatefulWidget {
  final AppController app;
  final Json session;
  final String? device;
  final VoidCallback showMap;
  const SessionPage(
    this.app,
    this.session, {
    super.key,
    this.device,
    required this.showMap,
  });
  @override
  State<SessionPage> createState() => _SessionState();
}

class _SessionState extends State<SessionPage> {
  List<Json>? points;
  String? error;
  bool exporting = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final p = await widget.app.series(
        widget.session,
        deviceId: widget.device,
      );
      if (mounted) setState(() => points = p);
    } catch (e) {
      if (mounted) setState(() => error = explain(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session, ds = objects(s['start']['devices']);
    return Scaffold(
      appBar: AppBar(title: Text(s['start']['name'] as String? ?? 'Mérés')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '${date(s['start']['started_at'])} – ${date(s['end']?['ended_at'])}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: exporting
                    ? null
                    : () async {
                        setState(() => exporting = true);
                        await guard(context, () async {
                          final ok = await exportCsv(
                            'meres-${s['id']}.csv',
                            widget.app.samples(s),
                          );
                          if (ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('CSV mentve.')),
                            );
                          }
                        });
                        if (mounted) setState(() => exporting = false);
                      },
                icon: const Icon(Icons.download),
                label: Text(exporting ? 'Exportálás…' : 'CSV export'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.showMap();
                },
                icon: const Icon(Icons.map_outlined),
                label: const Text('Megnézem a térképen'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (error != null)
            Hint(error!, warning: true)
          else if (points == null)
            const Center(child: CircularProgressIndicator())
          else
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nyomás · átlag és min/max tartomány',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 20),
                  PressureChart([
                    for (final d in ds)
                      points!
                          .where((p) => p['device_id'] == d['device_id'])
                          .toList(),
                  ], history: true),
                  Wrap(
                    spacing: 20,
                    children: [
                      for (final d in ds)
                        Text(
                          '${d['role']}: ${widget.app.device(d['device_id'])['name']}',
                          style: TextStyle(
                            color: d['role'] == 'A' ? green : blue,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          for (final d in ds)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${d['role']} · ${widget.app.device(d['device_id'])['name']}',
              ),
              subtitle: Text(
                '${d['device_id']} · ${d['calibration']?['verified'] == true ? 'ellenőrzött' : 'ellenőrizendő'} tartomány',
              ),
              trailing: Text(
                '${s['end']?['expected_samples_by_device']?[d['device_id']] ?? '—'} minta',
              ),
            ),
          const SizedBox(height: 12),
          Hint(
            s['start']['gps_enabled'] == true
                ? 'A hiányzó vagy pontatlan GPS-szel rögzített minták a grafikonban és az exportban megmaradnak. Csak az érvényes helyadatú minták kerülnek térképre.'
                : 'Ez a mérés GPS nélkül készült. Minden nyomásadat időbélyeggel elérhető.',
          ),
          if (objects(s['end']?['gaps']).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Hint(
                '${objects(s['end']['gaps']).length} észlelt kapcsolati vagy adathiány. A hiányokat nem pótoljuk mesterségesen.',
                warning: true,
              ),
            ),
        ],
      ),
    );
  }
}
