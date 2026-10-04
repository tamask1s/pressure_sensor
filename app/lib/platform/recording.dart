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

Future<void> holdRecording(bool enabled, {bool location = false}) async {
  if (Platform.isAndroid && enabled) await Permission.notification.request();
  await nativeRecording.invokeMethod<void>(enabled ? 'start' : 'stop', {
    'location': location,
  });
}
