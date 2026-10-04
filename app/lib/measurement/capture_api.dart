import '../core/model.dart';
import '../storage/store_api.dart';

abstract class Capture {
  Stream<Json> get events;
  Json get state;
  Future<void> scan();
  Future<Json> inspect(String peripheral);
  Future<Json> command(String device, Json command);
  Future<void> select(List<Json> devices);
  Future<void> disconnect(String device);
  Future<void> start(Store store, String id, Json session);
  Future<void> stop({bool interrupted = false});
  Future<void> recover(Store store);
  Future<void> dispose();
}
