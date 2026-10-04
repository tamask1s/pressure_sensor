import 'dart:convert';
import 'model.dart';

Stream<List<int>> csvBytes(Stream<List<Json>> pages) async* {
  yield utf8.encode(
    '\uFEFFcaptured_at_utc,device_id,boot_id,seq,pressure_pa,pressure_bar,raw_count,battery_mv,soc_pct,flags,latitude,longitude,accuracy_m,speed_mps\r\n',
  );
  String cell(Object? value) {
    if (value == null) return '';
    var s = value.toString();
    if (RegExp(r'^[=+@\t\r]').hasMatch(s)) s = "'$s";
    return '"${s.replaceAll('"', '""')}"';
  }

  await for (final page in pages) {
    final out = StringBuffer();
    for (final s in page) {
      final l = s['location'];
      out.writeln(
        [
          s['captured_at'],
          s['device_id'],
          s['boot_id'],
          s['seq'],
          s['pressure_pa'],
          s['pressure_pa'] == null ? null : (s['pressure_pa'] as num) / 100000,
          s['raw_count'],
          s['battery_mv'],
          s['soc_pct'],
          (s['flags'] as List).join('|'),
          l?['latitude'],
          l?['longitude'],
          l?['accuracy_m'],
          l?['speed_mps'],
        ].map(cell).join(','),
      );
    }
    yield utf8.encode(out.toString());
  }
}
