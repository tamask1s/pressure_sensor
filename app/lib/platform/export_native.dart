import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../core/model.dart';
import '../core/csv.dart';

Future<bool> exportCsv(String name, Stream<List<Json>> pages) async {
  final file = File(
    '${(await getTemporaryDirectory()).path}/pressure-${ids.v4()}.csv',
  );
  final out = file.openWrite();
  try {
    await out.addStream(csvBytes(pages));
    await out.flush();
    await out.close();
    if (Platform.isAndroid) {
      return await const MethodChannel(
            'hu.helti.pressure_field/export',
          ).invokeMethod<bool>('save', {'path': file.path, 'name': name}) ??
          false;
    }
    final destination = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (destination == null) return false;
    await XFile(file.path).saveTo(destination.path);
    return true;
  } finally {
    await out.close();
    if (await file.exists()) await file.delete();
  }
}
