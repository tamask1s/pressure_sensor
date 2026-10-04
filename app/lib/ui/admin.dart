import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../core/model.dart';
import '../sync/api.dart';

class AdminDevicesPage extends StatefulWidget {
  final Api api;
  final Future<XFile?> Function()? pickFile;
  const AdminDevicesPage(this.api, {super.key, this.pickFile});
  @override
  State<AdminDevicesPage> createState() => _AdminDevicesState();
}

class _AdminDevicesState extends State<AdminDevicesPage> {
  final search = TextEditingController();
  List<Json> items = [];
  String query = '', fileName = '', notice = '';
  String? cursor, next;
  final List<String?> previous = [];
  // Secrets stay in page memory only; never saved to the vault.
  Object? pending;
  Json? preview;
  bool busy = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    pending = null;
    search.dispose();
    super.dispose();
  }

  String message(Object error) => error is UserError
      ? error.message
      : 'A művelet nem sikerült. Próbáld meg újra.';

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final result = await widget.api.call(
        'GET',
        '/admin/devices',
        query: {
          'limit': '50',
          'q': query,
          if (cursor != null) 'cursor': cursor!,
        },
      );
      if (!mounted) return;
      setState(() {
        items = objects(result['items']);
        next = result['next_cursor'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => notice = message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose() async {
    setState(() {
      busy = true;
      pending = null;
      preview = null;
      notice = fileName = '';
    });
    try {
      final file =
          await (widget.pickFile?.call() ??
              openFile(
                acceptedTypeGroups: [
                  const XTypeGroup(label: 'JSON', extensions: ['json']),
                ],
              ));
      if (!mounted || file == null) return;
      if (await file.length() > 524288) {
        throw const UserError('A fájl legfeljebb 512 KiB méretű lehet.');
      }
      final Object? data;
      try {
        data = jsonDecode(await file.readAsString());
      } catch (_) {
        throw const UserError('A fájl nem érvényes JSON.');
      }
      if (data is! Map && data is! List) {
        throw const UserError('Gyártási rekordot vagy JSON-listát válassz.');
      }
      if (!mounted) return;
      final result = await widget.api.call(
        'POST',
        '/admin/devices/import',
        query: {'dry_run': 'true'},
        body: data,
      );
      if (!mounted) return;
      setState(() {
        fileName = file.name;
        preview = result;
        pending = result['valid'] == true ? data : null;
      });
    } catch (e) {
      if (mounted) setState(() => notice = message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submitImport() async {
    if (pending == null) return;
    setState(() => busy = true);
    try {
      final result = await widget.api.call(
        'POST',
        '/admin/devices/import',
        query: {'dry_run': 'false'},
        body: pending,
      );
      if (!mounted) return;
      setState(() {
        notice =
            'Import kész: ${result['counts']['new']} új eszköz, '
            '${result['counts']['unchanged']} változatlan.';
        pending = null;
        preview = null;
        fileName = '';
        cursor = null;
        previous.clear();
        query = '';
        search.clear();
      });
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          notice = message(e);
          pending = null;
          preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void find() {
    query = search.text.trim();
    cursor = null;
    previous.clear();
    notice = '';
    load();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Eszköznyilvántartás',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      const Text(
        'Az összes gyártói eszköz és jelenlegi tulajdonosa. Az import után '
        'a vásárló az appban, BLE-párosítással veszi fel az eszközt.',
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : choose,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('JSON kiválasztása és ellenőrzése'),
          ),
          FilledButton.icon(
            onPressed: busy || pending == null ? null : submitImport,
            icon: const Icon(Icons.upload),
            label: const Text('Importálás'),
          ),
        ],
      ),
      const Text(
        'Egy gyártási rekord vagy devices.simulator.json · legfeljebb 500 eszköz, 512 KiB',
      ),
      if (fileName.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 12), child: Text(fileName)),
      if (preview != null) ...[
        const SizedBox(height: 12),
        Text(
          '${preview!['counts']['new']} új · '
          '${preview!['counts']['unchanged']} változatlan · '
          '${preview!['counts']['conflict']} ütközés',
        ),
        Text(
          preview!['valid'] == true
              ? 'Az ellenőrzés sikerült. Az Importálás gombbal mentheted.'
              : 'Ütközés miatt a teljes fájl elutasítva. Nem módosult eszköz.',
        ),
        for (final item in objects(
          preview!['items'],
        ).where((i) => i['status'] == 'conflict'))
          SelectableText('Ütköző azonosító: ${item['device_id']}'),
      ],
      if (notice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(notice, semanticsLabel: notice),
        ),
      const SizedBox(height: 24),
      TextField(
        controller: search,
        enabled: !busy,
        maxLength: 32,
        decoration: InputDecoration(
          labelText: 'Keresés eszközazonosító szerint',
          suffixIcon: IconButton(
            tooltip: 'Keresés',
            onPressed: busy ? null : find,
            icon: const Icon(Icons.search),
          ),
        ),
        onSubmitted: (_) => find(),
      ),
      if (busy) const LinearProgressIndicator(),
      if (!busy && items.isEmpty) const Text('Nincs ilyen eszköz.'),
      for (final item in items)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  item['device_id'],
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(switch (item['status']) {
                  'paired' => 'Párosított',
                  'retired' => 'Visszavont · átadás szükséges',
                  _ => 'Regisztrált · még nincs tulajdonosa',
                }),
                if (item['owner'] != null) ...[
                  SelectableText('Tulajdonos: ${item['owner']['email']}'),
                  SelectableText('Fiók: ${item['owner']['account_id']}'),
                ],
                Text(
                  'Szenzor: ${item['sensor_serial']} · Protokoll: ${item['protocol_version']}',
                ),
                if (item['firmware_version'] != null)
                  Text('Firmware: ${item['firmware_version']}'),
              ],
            ),
          ),
        ),
      Wrap(
        spacing: 12,
        children: [
          TextButton(
            onPressed: busy || previous.isEmpty
                ? null
                : () {
                    cursor = previous.removeLast();
                    load();
                  },
            child: const Text('Előző oldal'),
          ),
          TextButton(
            onPressed: busy || next == null
                ? null
                : () {
                    previous.add(cursor);
                    cursor = next;
                    load();
                  },
            child: const Text('Következő oldal'),
          ),
          TextButton(
            onPressed: busy ? null : load,
            child: const Text('Frissítés'),
          ),
        ],
      ),
    ],
  );
}
