import '../core/model.dart';
import '../storage/store_api.dart';
import 'capture_api.dart';

Capture createCapture({bool simulated = false, int simulationPort = 47832}) =>
    WebCapture();

class WebCapture implements Capture {
  @override
  Stream<Json> get events => const Stream.empty();
  @override
  Json get state => {
    'active': false,
    'channels': <String, Json>{},
    'gps': 'A helyadatot a mérőapp rögzíti.',
  };
  Never unavailable() => throw const UserError(
    'BLE-méréshez az Android vagy Windows alkalmazást használd.',
  );
  @override
  Future<void> scan() async => unavailable();
  @override
  Future<Json> inspect(String p) async => unavailable();
  @override
  Future<Json> command(String d, Json c) async => unavailable();
  @override
  Future<void> select(List<Json> d) async => unavailable();
  @override
  Future<void> disconnect(String d) async => unavailable();
  @override
  Future<void> start(Store s, String id, Json data) async => unavailable();
  @override
  Future<void> stop({bool interrupted = false}) async {}
  @override
  Future<void> recover(Store s) async {}
  @override
  Future<void> dispose() async {}
}
