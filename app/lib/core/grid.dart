import 'dart:math' as math;
import 'package:proj4dart/proj4dart.dart' as proj;
import 'location.dart';
import 'model.dart';

class GridSpec {
  final int srid, size;
  late final proj.Projection projection;
  GridSpec(this.srid, this.size) {
    final zone = srid % 100;
    if (!(srid >= 32601 && srid <= 32660 || srid >= 32701 && srid <= 32760) ||
        ![10, 20, 50, 100, 250, 500, 1000].contains(size)) {
      throw const FormatException('Érvénytelen térképrács');
    }
    projection = proj.Projection.parse(
      '+proj=utm +zone=$zone ${srid >= 32700 ? '+south' : ''} +datum=WGS84 +units=m +no_defs',
    );
  }
  factory GridSpec.at(double lat, double lon, int size) => GridSpec(
    (lat >= 0 ? 32600 : 32700) + ((lon + 180) / 6).floor().clamp(0, 59) + 1,
    size,
  );
  proj.Point project(double lat, double lon) =>
      proj.Projection.WGS84.transform(projection, proj.Point(x: lon, y: lat));
  List<double> unproject(double x, double y) {
    final p = projection.transform(
      proj.Projection.WGS84,
      proj.Point(x: x, y: y),
    );
    return [p.x, p.y];
  }

  Json geometry(int x, int y) => {
    'type': 'Polygon',
    'coordinates': [
      [
        unproject(x * size.toDouble(), y * size.toDouble()),
        unproject((x + 1) * size.toDouble(), y * size.toDouble()),
        unproject((x + 1) * size.toDouble(), (y + 1) * size.toDouble()),
        unproject(x * size.toDouble(), (y + 1) * size.toDouble()),
        unproject(x * size.toDouble(), y * size.toDouble()),
      ],
    ],
  };
}

class _Stats {
  double sum = 0;
  int count = 0;
  double min = double.infinity, max = double.negativeInfinity;
  void add(num value) {
    sum += value;
    count++;
    min = math.min(min, value.toDouble());
    max = math.max(max, value.toDouble());
  }

  double get mean => sum / count;
}

/// Keeps only per-second totals, not the complete raw measurement in memory.
class PressureGrid {
  final GridSpec grid;
  final bool movingOnly;
  final String layer;
  final Map<String, List<Json>> fixes;
  final Map<String, Map<int, Map<String, _Stats>>> _seconds = {};
  int excluded = 0, missing = 0;
  PressureGrid(
    this.grid,
    this.fixes, {
    this.movingOnly = true,
    this.layer = 'combined',
  });
  void add(String session, String role, Json sample) {
    if (layer != 'combined' && layer != role) return;
    final flags = List<String>.from(sample['flags']);
    final location = sample['location'];
    if (location == null) {
      missing++;
      return;
    }
    if (sample['pressure_pa'] == null ||
        flags.contains('sensor_error') ||
        flags.contains('pressure_out_of_range') ||
        flags.contains('time_uncertain') ||
        (location['accuracy_m'] as num) > 10 ||
        (movingOnly &&
            (location['speed_mps'] == null ||
                (location['speed_mps'] as num) < 0.5))) {
      excluded++;
      return;
    }
    final sec = milliseconds(sample['captured_at']) ~/ 1000;
    ((_seconds[session] ??= {})[sec] ??= {})
        .putIfAbsent(role, _Stats.new)
        .add(sample['pressure_pa'] as num);
  }

  Json finish() {
    final cells = <String, Json>{};
    for (final session in _seconds.entries) {
      final perCell = <String, Json>{};
      for (final second in session.value.entries) {
        final loc = interpolate(
          fixes[session.key] ?? [],
          second.key * 1000 + 500,
        );
        if (loc == null) continue;
        final point = grid.project(
          (loc['latitude'] as num).toDouble(),
          (loc['longitude'] as num).toDouble(),
        );
        final x = (point.x / grid.size).floor(),
            y = (point.y / grid.size).floor(),
            key = '$x:$y';
        final c = perCell.putIfAbsent(
          key,
          () => {
            'ix': x,
            'iy': y,
            'totals': _Stats(),
            'sample_count': 0,
            'channels': <String>{},
            'partial_channel_seconds': 0,
            'min_pa': double.infinity,
            'max_pa': double.negativeInfinity,
          },
        );
        final channels = second.value.values;
        (c['totals'] as _Stats).add(
          channels.fold(0.0, (sum, s) => sum + s.mean) / channels.length,
        );
        c['sample_count'] += channels.fold(0, (sum, s) => sum + s.count);
        (c['channels'] as Set<String>).addAll(second.value.keys);
        if (channels.length < 2) c['partial_channel_seconds']++;
        for (final s in channels) {
          c['min_pa'] = math.min(c['min_pa'] as double, s.min);
          c['max_pa'] = math.max(c['max_pa'] as double, s.max);
        }
      }
      for (final entry in perCell.entries) {
        final p = entry.value;
        final c = cells.putIfAbsent(
          entry.key,
          () => {
            'ix': p['ix'],
            'iy': p['iy'],
            'totals': _Stats(),
            'sample_count': 0,
            'channels': <String>{},
            'partial_channel_seconds': 0,
            'min_pa': double.infinity,
            'max_pa': double.negativeInfinity,
          },
        );
        (c['totals'] as _Stats).add((p['totals'] as _Stats).mean);
        c['sample_count'] += p['sample_count'];
        c['partial_channel_seconds'] += p['partial_channel_seconds'];
        (c['channels'] as Set<String>).addAll(p['channels'] as Set<String>);
        c['min_pa'] = math.min(c['min_pa'] as double, p['min_pa'] as double);
        c['max_pa'] = math.max(c['max_pa'] as double, p['max_pa'] as double);
      }
    }
    if (cells.length > 5000) {
      throw const UserError(
        'Túl sok térképcella. Válassz nagyobb cellaméretet vagy szűkebb időszakot.',
      );
    }
    final values = cells.values.map((c) {
      final s = c.remove('totals') as _Stats;
      c['mean_pa'] = s.mean;
      c['session_count'] = s.count;
      c['channel_count'] = (c.remove('channels') as Set).length;
      c['geometry'] = grid.geometry(c['ix'] as int, c['iy'] as int);
      return c;
    }).toList();
    values.sort((a, b) {
      final x = (a['ix'] as int).compareTo(b['ix'] as int);
      return x != 0 ? x : (a['iy'] as int).compareTo(b['iy'] as int);
    });
    return {
      'algorithm': 'pressure-grid-v1',
      'grid_srid': grid.srid,
      'cell_m': grid.size,
      'scale': {'min_pa': 0, 'max_pa': 20000000},
      'cells': values,
      'quality': {
        'excluded_samples': excluded,
        'missing_location_samples': missing,
      },
    };
  }
}
