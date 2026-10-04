import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../controller.dart';
import '../core/model.dart';
import 'common.dart';

class DevicesPage extends StatelessWidget {
  final AppController app;
  const DevicesPage(this.app, {super.key});
  Future<void> scan(BuildContext context) async {
    if (app.recording) return;
    await guard(context, () async {
      await app.capture.scan();
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => _AddDevice(app),
        );
      }
    });
  }

  Future<void> pair(BuildContext context) async {
    final available = app.devices
        .where(
          (d) => !app.rigs.any(
            (r) => r['device_a_id'] == d['id'] || r['device_b_id'] == d['id'],
          ),
        )
        .toList();
    if (available.length < 2) {
      await guard(context, () async {
        throw const UserError('Legalább két, még szabad készülék szükséges.');
      });
      return;
    }
    final name = TextEditingController();
    String a = available[0]['id'], b = available[1]['id'];
    bool busy = false;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Új eszközpár'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Pár neve',
                    hintText: 'Például: 1. traktor',
                  ),
                ),
                const SizedBox(height: 20),
                for (final role in ['A', 'B'])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: DropdownButtonFormField<String>(
                      initialValue: role == 'A' ? a : b,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: '$role csatorna'),
                      items: [
                        for (final d in available)
                          DropdownMenuItem(
                            value: d['id'] as String,
                            child: Text('${d['name']} · ${shortId(d['id'])}'),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => set(() => role == 'A' ? a = v! : b = v!),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Mégse'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      set(() => busy = true);
                      await guard(context, () async {
                        await app.saveRig(name.text, a, b);
                        if (context.mounted) Navigator.pop(context);
                      });
                      if (context.mounted) set(() => busy = false);
                    },
              child: Text(busy ? 'Mentés…' : 'Pár létrehozása'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 16,
        runSpacing: 16,
        children: [
          Text(
            'Eszközeid és párjaik',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!app.local)
                IconButton(
                  tooltip: 'Lista frissítése',
                  onPressed: () => guard(context, app.refreshCatalog),
                  icon: const Icon(Icons.refresh),
                ),
              if (!kIsWeb)
                OutlinedButton.icon(
                  onPressed: app.recording ? null : () => scan(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Készülék hozzáadása'),
                ),
              FilledButton.icon(
                onPressed: app.recording ? null : () => pair(context),
                icon: const Icon(Icons.link),
                label: const Text('Új pár'),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 24),
      if (kIsWeb)
        const Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: Hint(
            'Új készüléket az Android- vagy Windows-appal tudsz a fiókodhoz rendelni. A párok itt is kezelhetők.',
          ),
        ),
      if (app.devices.isEmpty)
        const Empty(
          Icons.sensors,
          'Még nincs készülék',
          'Kapcsold be az érzékelőt, majd tartsd nyomva a Bluetooth-gombját 1,5 másodpercig. A párosításkor add meg a készülék címkéjén lévő PIN-t.',
        ),
      for (final r in app.rigs)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Panel(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.agriculture_outlined,
                color: green,
                size: 32,
              ),
              title: Text(r['name'] as String),
              subtitle: Text(
                'A: ${app.device(r['device_a_id'])['name']}    B: ${app.device(r['device_b_id'])['name']}',
              ),
              trailing: PopupMenuButton<String>(
                tooltip: 'Pár kezelése',
                onSelected: (v) => guard(context, () async {
                  if (await confirm(
                    context,
                    'Pár archiválása',
                    'A készülékek felszabadulnak. A korábbi mérések megmaradnak.',
                  )) {
                    await app.archiveRig(r);
                  }
                }),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'archive',
                    enabled: !app.recording,
                    child: const Text('Archiválás'),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (app.devices.isNotEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Text(
            'KÉSZÜLÉKEK',
            style: TextStyle(
              letterSpacing: 1.4,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      for (final d in app.devices)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Panel(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sensors, color: green),
              title: Text(d['name'] as String? ?? d['id']),
              subtitle: Text(
                '${d['id']}\nFirmware: ${d['firmware_version'] ?? '—'} · ${d['calibration']?['verified'] == true ? 'ellenőrzött tartomány' : 'tartomány ellenőrzendő'}${d['presence']?['last_seen_at'] != null ? '\nUtoljára elérhető: ${date(d['presence']['last_seen_at'])}' : ''}',
              ),
              isThreeLine: true,
              trailing: IconButton(
                tooltip: 'Átnevezés',
                onPressed: () => guard(context, () async {
                  final name = await askText(
                    context,
                    'Készülék neve',
                    initial: d['name'] as String? ?? '',
                  );
                  if (name != null) await app.rename(d['id'], name);
                }),
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
          ),
        ),
    ],
  );
}

class _AddDevice extends StatefulWidget {
  final AppController app;
  const _AddDevice(this.app);
  @override
  State<_AddDevice> createState() => _AddState();
}

class _AddState extends State<_AddDevice> {
  bool busy = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) => AlertDialog(
      title: const Text('Közeli készülékek'),
      content: SizedBox(
        width: 460,
        height: 330,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tartsd nyomva a készülék Bluetooth-gombját 1,5 másodpercig. A párosítási ablak 2 perc; a PIN a készülék címkéjén található.',
            ),
            const SizedBox(height: 16),
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                children: [
                  for (final d in objects(
                    widget.app.capture.state['discovered'],
                  ))
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(d['name']),
                      subtitle: Text('${d['rssi']} dBm'),
                      enabled: !busy,
                      onTap: () async {
                        setState(() => busy = true);
                        await guard(context, () async {
                          await widget.app.addDevice(d['peripheral'], '');
                          if (context.mounted) Navigator.pop(context);
                        });
                        if (mounted) setState(() => busy = false);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Bezárás'),
        ),
      ],
    ),
  );
}
