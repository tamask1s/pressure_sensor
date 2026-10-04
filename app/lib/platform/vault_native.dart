import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/model.dart';

const _storage = FlutterSecureStorage();
Future<Json?> readVault(String key) async {
  final value = await _storage.read(key: key);
  return value == null ? null : object(jsonDecode(value));
}

Future<void> writeVault(String key, Json? value) => value == null
    ? _storage.delete(key: key)
    : _storage.write(key: key, value: jsonEncode(value));
