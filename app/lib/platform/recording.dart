import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/model.dart';

const nativeRecording = MethodChannel('hu.helti.pressure_field/recording');
Future<void> bluetoothPermission() async {
  if (!Platform.isAndroid) return;
  final sdk = await nativeRecording.invokeMethod<int>('sdk') ?? 31;
  final result = await [
    if (sdk >= 31) ...[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ] else
      Permission.locationWhenInUse,
  ].request();
  if (result[Permission.bluetoothScan] == PermissionStatus.permanentlyDenied ||
      result[Permission.bluetoothConnect] ==
          PermissionStatus.permanentlyDenied) {
    throw const UserError(
      'A Bluetooth-engedélyt a telefon alkalmazásbeállításaiban tudod visszakapcsolni.',
    );
  }
}

final _recorders = <Object, bool>{};
final _defaultRecorder = Object();
Future<void> _recordingChange = Future.value();

Future<void> holdRecording(
  bool enabled, {
  bool location = false,
  Object? owner,
}) {
  final key = owner ?? _defaultRecorder;
  final result = _recordingChange.then((_) async {
    final next = {..._recorders};
    if (enabled) {
      next[key] = location;
    } else {
      next.remove(key);
    }
    if (next.isNotEmpty &&
        (_recorders.isEmpty ||
            next.values.any((v) => v) != _recorders.values.any((v) => v))) {
      if (Platform.isAndroid && _recorders.isEmpty) {
        await Permission.notification.request();
      }
      await nativeRecording.invokeMethod<void>('start', {
        'location': next.values.any((v) => v),
      });
    } else if (next.isEmpty && _recorders.isNotEmpty) {
      await nativeRecording.invokeMethod<void>('stop');
    }
    _recorders
      ..clear()
      ..addAll(next);
  });
  _recordingChange = result.catchError((Object _) {});
  return result;
}
