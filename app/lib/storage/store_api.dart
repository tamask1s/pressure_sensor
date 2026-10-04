import '../core/model.dart';

abstract class Store {
  Future<Json?> meta(String key);
  Future<void> putMeta(String key, Json value);
  Future<void> startSession(String id, Json start);
  Future<List<Json>> sessions();
  Future<void> finishSession(String id, Json end);
  Future<void> writeRecords(String session, List<Json> records);
  Future<List<Json>> pendingSamples(String session, {int limit = 1000});
  Future<void> finalizeSamples(List<Json> samples);
  Stream<List<Json>> records(String session, String kind);
  Future<Json?> nextBatch(String session);
  Future<void> acknowledge(String batchId);
  Future<void> markStarted(String session);
  Future<void> markComplete(String session);
  Future<int> pendingCount();
  Future<Map<String, int>> counts(String session);
  Future<void> close();
}

Json record(String kind, Json data, {bool ready = true}) => {
  'kind': kind,
  'id': kind == 'samples'
      ? '${data['device_id']}/${data['boot_id']}/${data['seq']}'
      : data['id'],
  'data': data,
  'ready': ready,
};
