import 'dart:convert';
import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;
const ids = Uuid();
Json object(Object? value) => Map<String, dynamic>.from(value as Map);
List<Json> objects(Object? value) =>
    (value as List? ?? []).map(object).toList();
int milliseconds(Object? time) =>
    DateTime.parse(time as String).millisecondsSinceEpoch;
String utc(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();
Json copyJson(Json j) => object(jsonDecode(jsonEncode(j)));
String shortId(String id) =>
    id.length > 6 ? id.substring(id.length - 6).toUpperCase() : id;

Json calibration(Json info) => {
  'profile_id':
      '${info['device_id']}-${info['range_min_pa']}-${info['range_max_pa']}',
  'sensor_serial': info['sensor_serial'],
  'range_min_pa': info['range_min_pa'],
  'range_max_pa': info['range_max_pa'],
  'scale': 1,
  'offset_pa': 0,
  'verified': info['calibration_verified'] == true,
};

class UserError implements Exception {
  final String message;
  const UserError(this.message);
  @override
  String toString() => message;
}

String explain(Object error) {
  if (error is UserError) return error.message;
  final text = error.toString();
  if (text.contains('SocketException') || text.contains('ClientException')) {
    return 'A szolgáltatás most nem érhető el. A helyi mérés folytatható.';
  }
  if (text.contains('TimeoutException')) {
    return 'A művelet időtúllépés miatt megszakadt. Próbáld újra.';
  }
  return 'Nem sikerült a művelet: $text';
}
