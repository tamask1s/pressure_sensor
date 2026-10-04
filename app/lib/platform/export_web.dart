import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import '../core/model.dart';
import '../core/csv.dart';

Future<bool> exportCsv(String name, Stream<List<Json>> pages) async {
  final parts = <JSAny>[];
  await for (final bytes in csvBytes(pages)) {
    parts.add(Uint8List.fromList(bytes).toJS);
  }
  final blob = web.Blob(
    parts.toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob),
      a = web.HTMLAnchorElement()
        ..href = url
        ..download = name;
  web.document.body!.append(a);
  a.click();
  a.remove();
  Future<void>.delayed(
    const Duration(minutes: 1),
    () => web.URL.revokeObjectURL(url),
  );
  return true;
}
