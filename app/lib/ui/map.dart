import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../controller.dart';
import '../core/model.dart';
import '../core/grid.dart';
import 'common.dart';

class MapPage extends StatefulWidget {
  final AppController app;
  final Json? session;
  const MapPage(this.app, {super.key, this.session});
  @override
  State<MapPage> createState() => _MapState();
}

class _MapState extends State<MapPage> {
  final controller = MapController();
  int cell = 10, days = 30;
  String layer = 'combined', rig = '';
  bool moving = true,
      cloud = false,
      busy = false,
      mapReady = false,
      initialized = false;
  Json? result;
  String? message;
  int? gridSrid;
  bool raw = false;
  List<Json> rawPoints = [];
  List<List<LatLng>> tracks = [];
  LatLng center = const LatLng(47.1, 19.5);
  @override
  void initState() {
    super.initState();
    cloud = kIsWeb || (!widget.app.local && widget.session?['local'] != true);
  }

  List<Json> selected() {
    final since = DateTime.now().subtract(Duration(days: days));
    return widget.app.history
        .where(
          (s) =>
              (widget.session == null || s['id'] == widget.session!['id']) &&
              (cloud || s['local'] == true) &&
              (rig.isEmpty || s['start']['rig_id'] == rig) &&
              (widget.session != null ||
                  DateTime.parse(s['start']['started_at']).isAfter(since)),
        )
        .toList();
  }

  Future<void> locate() async {
    final sessions = widget.session == null ? selected() : [widget.session!];
    for (final s in sessions) {
      List<Json> fixes = [];
      if (s['local'] == true && widget.app.store != null) {
        await for (final page in widget.app.store!.records(
          s['id'],
          'gps_fixes',
        )) {
          fixes = page;
          break;
        }
      } else {
        final page = await widget.app.api.call(
          'GET',
          '/sessions/${s['id']}/track',
          query: {'limit': '1'},
        );
        fixes = objects(page['items']);
      }
      if (fixes.isNotEmpty) {
        final f = fixes.first;
        center = LatLng(
          (f['latitude'] as num).toDouble(),
          (f['longitude'] as num).toDouble(),
        );
        if (mapReady) controller.move(center, 16);
        return;
      }
    }
    final p = widget.app.capture.state['position'];
    if (p != null) {
      center = LatLng(p['latitude'], p['longitude']);
      if (mapReady) controller.move(center, 16);
    }
  }

  Future<void> load({bool recenter = false}) async {
    if (busy || !mapReady) return;
    setState(() => busy = true);
    try {
      if (recenter || !initialized) {
        await locate();
        initialized = true;
      }
      center = controller.camera.center;
      if (recenter) gridSrid = null;
      gridSrid ??= GridSpec.at(center.latitude, center.longitude, cell).srid;
      final spec = GridSpec(gridSrid!, cell);
      Json data;
      if (cloud) {
        final b = controller.camera.visibleBounds;
        final start =
            widget.session?['start']['started_at'] ??
            DateTime.now()
                .toUtc()
                .subtract(Duration(days: days))
                .toIso8601String();
        final end =
            widget.session?['end']?['ended_at'] ??
            DateTime.now().toUtc().toIso8601String();
        data = await widget.app.api.call(
          'GET',
          '/map/cells',
          query: {
            'from': start,
            'to': end,
            'bbox': '${b.west},${b.south},${b.east},${b.north}',
            'grid_srid': '${spec.srid}',
            'cell_m': '$cell',
            'layer': layer,
            'moving_only': '$moving',
            if (rig.isNotEmpty) 'rig_ids': rig,
            if (widget.session != null) 'session_ids': widget.session!['id'],
          },
        );
      } else {
        data = await widget.app.localMap(
          selected(),
          spec,
          layer: layer,
          moving: moving,
        );
      }
      final points = <Json>[];
      if (raw) {
        final bounds = controller.camera.visibleBounds;
        for (final s in selected()) {
          final roles = {
            for (final d in objects(s['start']['devices']))
              d['device_id']: d['role'],
          };
          await for (final page in widget.app.samples(s, forceRemote: cloud)) {
            for (final sample in page) {
              final loc = sample['location'];
              if (loc == null || sample['pressure_pa'] == null) continue;
              if (moving &&
                  (loc['speed_mps'] == null ||
                      (loc['speed_mps'] as num) < 0.5)) {
                continue;
              }
              if (layer != 'combined' && roles[sample['device_id']] != layer) {
                continue;
              }
              if (bounds.contains(LatLng(loc['latitude'], loc['longitude']))) {
                points.add(sample);
              }
              if (points.length >= 5000) break;
            }
            if (points.length >= 5000) break;
          }
          if (points.length >= 5000) break;
        }
      }
      final route = <List<LatLng>>[];
      if (widget.session != null) {
        final session = widget.session!, fixes = <Json>[];
        if (session['local'] == true && widget.app.store != null) {
          await for (final page in widget.app.store!.records(
            session['id'],
            'gps_fixes',
          )) {
            fixes.addAll(page);
          }
        } else {
          fixes.addAll(
            await widget.app.api.list('/sessions/${session['id']}/track'),
          );
        }
        Json? previous;
        var line = <LatLng>[];
        for (final fix in fixes) {
          if ((fix['accuracy_m'] as num) > 10) {
            if (line.length > 1) route.add(line);
            line = [];
            previous = null;
            continue;
          }
          if (previous != null &&
              (fix['segment_id'] != previous['segment_id'] ||
                  milliseconds(fix['captured_at']) -
                          milliseconds(previous['captured_at']) >
                      2000)) {
            if (line.length > 1) route.add(line);
            line = [];
          }
          line.add(
            LatLng(
              (fix['latitude'] as num).toDouble(),
              (fix['longitude'] as num).toDouble(),
            ),
          );
          previous = fix;
        }
        if (line.length > 1) route.add(line);
      }
      if (mounted) {
        setState(() {
          result = data;
          rawPoints = points;
          tracks = route;
          message = objects(data['cells']).isEmpty
              ? 'Nincs megjeleníthető helyadat a választott szűrésben. A GPS nélküli mérések az előzményekben elérhetők.'
              : points.length >= 5000
              ? 'Nyers nézet: az első 5000 látható minta. A cellaátlagok minden szűrt adatot figyelembe vesznek.'
              : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = explain(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Color heat(num p) => p <= 10000000
      ? Color.lerp(
          const Color(0xff30a77e),
          const Color(0xffe9c34b),
          (p / 10000000).clamp(0, 1),
        )!.withValues(alpha: .76)
      : Color.lerp(
          const Color(0xffe9c34b),
          const Color(0xffc74b41),
          ((p - 10000000) / 10000000).clamp(0, 1),
        )!.withValues(alpha: .76);
  void inspectCell(LatLng location) {
    if (result == null) return;
    final spec = GridSpec(result!['grid_srid'], result!['cell_m']),
        p = spec.project(location.latitude, location.longitude);
    final cell = objects(result!['cells'])
        .where(
          (c) =>
              c['ix'] == (p.x / spec.size).floor() &&
              c['iy'] == (p.y / spec.size).floor(),
        )
        .firstOrNull;
    if (cell == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${bar(cell['mean_pa'])} bar',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Minimum: ${bar(cell['min_pa'])} · Maximum: ${bar(cell['max_pa'])} bar\n${cell['sample_count']} minta · ${cell['session_count']} mérés · ${cell['channel_count']} csatorna\n${cell['partial_channel_seconds']} másodperc csak egy csatornával',
              ),
              const SizedBox(height: 12),
              Text(
                '${spec.size} m-es cella · EPSG:${spec.srid}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cells = objects(result?['cells']);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.session == null
                          ? 'A mérések közös térképe'
                          : widget.session!['start']['name'],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Ugrás a méréshez',
                    onPressed: busy ? null : () => load(recenter: true),
                    icon: const Icon(Icons.my_location),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (!kIsWeb && !widget.app.local)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, label: Text('Felhő')),
                            ButtonSegment(
                              value: false,
                              label: Text('Helyi adatok'),
                            ),
                          ],
                          selected: {cloud},
                          onSelectionChanged: busy
                              ? null
                              : (s) {
                                  setState(() => cloud = s.first);
                                  load();
                                },
                        ),
                      ),
                    _select<int>(
                      'Időszak',
                      days,
                      {7: '7 nap', 30: '30 nap', 365: '1 év', 36500: 'Összes'},
                      widget.session != null
                          ? null
                          : (v) {
                              setState(() => days = v);
                              load();
                            },
                    ),
                    _select<String>(
                      'Pár',
                      rig,
                      {
                        '': 'Minden pár',
                        for (final r in widget.app.rigs)
                          r['id'] as String: r['name'] as String,
                      },
                      widget.session != null
                          ? null
                          : (v) {
                              setState(() => rig = v);
                              load();
                            },
                    ),
                    _select(
                      'Réteg',
                      layer,
                      {
                        'combined': 'Közös A + B',
                        'A': 'A csatorna',
                        'B': 'B csatorna',
                      },
                      (v) {
                        setState(() => layer = v);
                        load();
                      },
                    ),
                    _select(
                      'Cellaméret',
                      cell,
                      {
                        for (final n in [10, 20, 50, 100, 250, 500, 1000])
                          n: '$n m',
                      },
                      (v) {
                        setState(() => cell = v);
                        load();
                      },
                    ),
                    FilterChip(
                      label: const Text('Csak haladás közben'),
                      selected: moving,
                      onSelected: busy
                          ? null
                          : (v) {
                              setState(() => moving = v);
                              load();
                            },
                    ),
                    const SizedBox(width: 12),
                    FilterChip(
                      label: const Text('Nyers mintapontok'),
                      selected: raw,
                      onSelected: busy
                          ? null
                          : (v) {
                              setState(() => raw = v);
                              load();
                            },
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: busy ? null : () => load(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Nézet frissítése'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 3),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Hint(message!),
          ),
        Expanded(
          child: FlutterMap(
            mapController: controller,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 7,
              minZoom: 3,
              maxZoom: 19,
              onTap: (_, point) => inspectCell(point),
              onMapReady: () {
                mapReady = true;
                load();
              },
            ),
            children: [
              TileLayer(
                urlTemplate: const String.fromEnvironment(
                  'TILE_URL',
                  defaultValue:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                ),
                userAgentPackageName: 'hu.helti.pressure_field',
                maxNativeZoom: 19,
              ),
              PolygonLayer(
                polygons: [
                  for (final c in cells)
                    Polygon(
                      points: [
                        for (final point
                            in (c['geometry']['coordinates'] as List).first
                                as List)
                          LatLng(
                            (point[1] as num).toDouble(),
                            (point[0] as num).toDouble(),
                          ),
                      ],
                      color: heat(c['mean_pa']),
                      borderColor: Colors.white.withValues(alpha: .15),
                      borderStrokeWidth: .3,
                    ),
                ],
              ),
              if (raw)
                CircleLayer(
                  circles: [
                    for (final p in rawPoints)
                      CircleMarker(
                        point: LatLng(
                          p['location']['latitude'],
                          p['location']['longitude'],
                        ),
                        radius: 3,
                        color: heat(p['pressure_pa']),
                        borderColor: ink,
                        borderStrokeWidth: .5,
                      ),
                  ],
                ),
              PolylineLayer(
                polylines: [
                  for (final line in tracks)
                    Polyline(
                      points: line,
                      color: blue.withValues(alpha: .6),
                      strokeWidth: 2,
                    ),
                ],
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Wrap(
            spacing: 20,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Nyomás · bar'),
              SizedBox(
                width: 170,
                child: Column(
                  children: [
                    Container(
                      height: 9,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xff30a77e),
                            Color(0xffe9c34b),
                            Color(0xffc74b41),
                          ],
                        ),
                      ),
                    ),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [Text('0'), Text('100'), Text('200')],
                    ),
                  ],
                ),
              ),
              Text(
                '${cells.length} cella · ${cloud ? 'fiók összes feltöltött adata' : 'helyben tárolt adatok'}',
              ),
              if (result?['quality'] != null)
                Text(
                  'Helyadat nélkül: ${result!['quality']['missing_location_samples'] ?? 0} minta',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _select<T>(
    String label,
    T value,
    Map<T, String> values,
    void Function(T)? change,
  ) => Padding(
    padding: const EdgeInsets.only(right: 12),
    child: SizedBox(
      width: label == 'Pár' ? 180 : 140,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          for (final e in values.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: busy || change == null ? null : (v) => change(v as T),
      ),
    ),
  );
}
