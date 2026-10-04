import 'dart:async';
import '../core/model.dart';
import '../core/protocol.dart';

class DevicePeer {
  final Json info;
  DeviceClock? clock;
  bool busy = false;
  DevicePeer(this.info);
}

abstract class DeviceHub {
  StreamController<Json> get events;
  Map<String, DevicePeer> get peers;
  Future<void> scan();
  Future<DevicePeer> connect(String peripheral, {String? expected});
  Future<Json> command(DevicePeer peer, Json command);
  Future<void> synchronize(DevicePeer peer);
  Future<void> select(List<Json> devices);
  Future<void> disconnect(String id);
  Future<void> dispose();
}
