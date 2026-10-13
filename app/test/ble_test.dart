import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pressure_field/measurement/ble.dart';

class TestCentral implements CentralManager {
  final states =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  @override
  BluetoothLowEnergyState state = BluetoothLowEnergyState.unknown;
  int scans = 0;
  void change(BluetoothLowEnergyState value) {
    state = value;
    states.add(BluetoothLowEnergyStateChangedEventArgs(value));
  }

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      states.stream;
  @override
  Stream<DiscoveredEventArgs> get discovered => const Stream.empty();
  @override
  Stream<PeripheralConnectionStateChangedEventArgs>
  get connectionStateChanged => const Stream.empty();
  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      const Stream.empty();
  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {
    scans++;
  }

  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> connect(Peripheral peripheral) async =>
      throw StateError('GATT failed');
  @override
  Future<void> disconnect(Peripheral peripheral) => Completer<void>().future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPeripheral implements Peripheral {
  @override
  final uuid = UUID.fromString('00000000-0000-0000-0000-000000000001');
}

void main() {
  test(
    'First scan waits for initialization; resume does not restart discovery',
    () async {
      final manager = TestCentral();
      final hub = BleHub(manager: manager);
      addTearDown(() async {
        await hub.dispose();
        await manager.states.close();
      });
      final scan = hub.scan();
      expect(manager.scans, 0);
      manager.change(BluetoothLowEnergyState.poweredOn);
      await scan;
      expect(manager.scans, 1);
      manager.change(BluetoothLowEnergyState.poweredOn);
      await Future<void>.delayed(Duration.zero);
      await hub.scan();
      expect(manager.scans, 1);
      manager.change(BluetoothLowEnergyState.poweredOff);
      await Future<void>.delayed(Duration.zero);
      manager.change(BluetoothLowEnergyState.poweredOn);
      await Future<void>.delayed(Duration.zero);
      await hub.scan();
      expect(manager.scans, 2);
    },
  );

  test(
    'Failed GATT cleanup cannot block every subsequent connection',
    () async {
      final manager = TestCentral()..state = BluetoothLowEnergyState.poweredOn;
      final hub = BleHub(manager: manager);
      addTearDown(() async {
        await hub.dispose();
        await manager.states.close();
      });
      final peripheral = TestPeripheral();
      final id = peripheral.uuid.toString();
      hub.discovered[id] = DiscoveredEventArgs(
        peripheral,
        -50,
        Advertisement(),
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          hub.connect(id).timeout(const Duration(seconds: 8)),
          throwsStateError,
        );
      }
    },
  );
}
