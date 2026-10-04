import '../core/model.dart';

// Web authentication lives in an HttpOnly cookie, never in browser storage.
final _memory = <String, Json>{};
Future<Json?> readVault(String key) async => _memory[key];
Future<void> writeVault(String key, Json? value) async {
  if (value == null) {
    _memory.remove(key);
  } else {
    _memory[key] = value;
  }
}
