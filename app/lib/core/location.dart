import 'model.dart';

Json? interpolate(List<Json> fixes, int at, {int uncertainty = 0}) {
  if (uncertainty > 100 || fixes.length < 2) return null;
  var lo = 0, hi = fixes.length;
  while (lo < hi) {
    final m = (lo + hi) ~/ 2;
    if (milliseconds(fixes[m]['captured_at']) <= at) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  if (lo == fixes.length && milliseconds(fixes.last['captured_at']) == at) lo--;
  if (lo == 0 || lo == fixes.length) return null;
  final a = fixes[lo - 1], b = fixes[lo];
  final ta = milliseconds(a['captured_at']),
      tb = milliseconds(b['captured_at']);
  if (tb <= ta ||
      tb - ta > 2000 ||
      a['segment_id'] != b['segment_id'] ||
      (a['accuracy_m'] as num) > 10 ||
      (b['accuracy_m'] as num) > 10 ||
      (a['accuracy_m'] as num) < 0 ||
      (b['accuracy_m'] as num) < 0) {
    return null;
  }
  final fraction = (at - ta) / (tb - ta);
  double mix(String k) =>
      (a[k] as num).toDouble() + ((b[k] as num) - (a[k] as num)) * fraction;
  return {
    'latitude': mix('latitude'),
    'longitude': mix('longitude'),
    'accuracy_m': ((a['accuracy_m'] as num) > (b['accuracy_m'] as num)
        ? a['accuracy_m']
        : b['accuracy_m']),
    'speed_mps': a['speed_mps'] != null && b['speed_mps'] != null
        ? mix('speed_mps')
        : null,
    'fix_before_id': a['id'],
    'fix_after_id': b['id'],
    'method': 'interpolated',
  };
}

Json finalizeLocation(
  Json sample,
  List<Json> fixes,
  bool enabled,
  int uncertainty,
) {
  final result = copyJson(sample), flags = List<String>.from(sample['flags']);
  if (flags.contains('time_uncertain')) uncertainty = 10001;
  result['location'] = enabled
      ? interpolate(
          fixes,
          milliseconds(sample['captured_at']),
          uncertainty: uncertainty,
        )
      : null;
  if (!enabled) {
    flags.add('gps_disabled');
  } else if (uncertainty > 100) {
    flags.add('time_uncertain');
  } else if (result['location'] == null) {
    flags.add('gps_missing');
  } else {
    final speed = result['location']['speed_mps'] as num?;
    if (speed == null || speed < 0) {
      flags.add('speed_unknown');
    } else if (speed < 0.5) {
      flags.add('stationary');
    }
  }
  result['flags'] = flags.toSet().toList();
  return result;
}
