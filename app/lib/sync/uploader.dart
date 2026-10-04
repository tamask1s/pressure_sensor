import '../core/model.dart';
import '../storage/store_api.dart';
import 'api.dart';

class Uploader {
  final Api api;
  final Store store;
  final String accountId;
  bool _running = false;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  int _failures = 0;
  String status = '';
  Uploader(this.api, this.store, this.accountId);
  Future<void> tick({bool force = false}) async {
    if (_running ||
        accountId == 'local' ||
        !api.configured ||
        (!force && DateTime.now().isBefore(_next))) {
      return;
    }
    _running = true;
    try {
      if (api.account?['id'] != accountId) {
        throw const UserError('A feltöltési sor másik fiókhoz tartozik.');
      }
      var budget = 20;
      for (final s in (await store.sessions()).reversed) {
        if (s['completed'] == true) continue;
        final id = s['id'] as String;
        if (s['started'] != true) {
          await api.call('PUT', '/sessions/$id', body: object(s['start']));
          await store.markStarted(id);
        }
        while (budget > 0) {
          final batch = await store.nextBatch(id);
          if (batch == null) break;
          final answer = await api.call(
            'POST',
            '/sessions/$id/batches',
            body: batch,
          );
          final expected =
              objects(batch['samples']).length +
              objects(batch['gps_fixes']).length +
              objects(batch['time_segments']).length;
          if (answer['batch_id'] != batch['batch_id'] ||
              answer['inserted'] is! int ||
              answer['duplicates'] is! int ||
              (answer['inserted'] as int) + (answer['duplicates'] as int) !=
                  expected) {
            throw const FormatException('Hiányos feltöltési nyugta');
          }
          await store.acknowledge(batch['batch_id'] as String);
          budget--;
        }
        if (budget == 0) break;
        if (s['end'] != null &&
            (await store.pendingSamples(id, limit: 1)).isEmpty) {
          await api.call(
            'POST',
            '/sessions/$id/complete',
            body: object(s['end']),
          );
          await store.markComplete(id);
        }
      }
      status = 'Feltöltés rendben';
      _failures = 0;
      _next = DateTime.now().add(const Duration(seconds: 5));
    } catch (e) {
      status = explain(e);
      _failures = (_failures + 1).clamp(1, 6);
      _next = DateTime.now().add(Duration(seconds: 1 << _failures));
    } finally {
      _running = false;
    }
  }
}
