import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/model.dart';
import 'engine.dart';

class SimulatorServer {
  final Simulation simulation;
  HttpServer? _server;
  WebSocket? _socket;
  final Set<String> _connected = {};
  Timer? _timer;
  int _lastGps = 0;
  bool _accepting = false;
  SimulatorServer(this.simulation);
  int get port => _server!.port;
  Future<void> start({int port = simulatorPort}) async {
    _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server!.listen((request) async {
      // A browser page cannot control this native-only loopback connection.
      if (request.uri.path != '/simulator' ||
          request.headers.value('origin') != null ||
          request.headers.value('x-pressure-simulator') != '1' ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (_socket != null || _accepting) {
        request.response.statusCode = HttpStatus.conflict;
        await request.response.close();
        return;
      }
      _accepting = true;
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        _socket = socket;
        socket.pingInterval = const Duration(seconds: 5);
        socket.listen(
          (data) => _request(socket, data),
          onError: (Object _) {},
          onDone: () {
            if (_socket == socket) {
              _socket = null;
              _connected.clear();
            }
          },
        );
        _send({'type': 'simulator', 'state': simulation.state});
      } catch (_) {
        await request.response.close();
      } finally {
        _accepting = false;
      }
    });
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _send(Json data) {
    if (_socket?.readyState == WebSocket.open) _socket!.add(jsonEncode(data));
  }

  void _disconnect(String id) {
    if (_connected.remove(id)) _send({'type': 'disconnected', 'device_id': id});
  }

  void _request(WebSocket socket, dynamic data) {
    int? id;
    try {
      if (data is! String || data.length > 8192) {
        throw const FormatException('Túl nagy kérés');
      }
      final c = object(jsonDecode(data));
      id = c['id'] as int;
      Json result;
      switch (c['op']) {
        case 'scan':
          result = {
            'devices': [
              for (final d in simulation.devices.where((d) => d.online))
                {
                  'peripheral': d.id,
                  'name':
                      'Szimulált ${d.index == 0 ? 'A' : 'B'} · ${shortId(d.id)}',
                  'rssi': -40,
                },
            ],
          };
          break;
        case 'connect':
          final d = simulation.device(c['device_id'] as String);
          if (!d.online) throw const UserError('Az eszköz ki van kapcsolva.');
          _connected.add(d.id);
          result = d.info(simulation.now);
          break;
        case 'disconnect':
          _disconnect(c['device_id'] as String);
          result = {};
          break;
        case 'device':
          final d = simulation.device(c['device_id'] as String);
          if (!d.online || !_connected.contains(d.id)) {
            throw const UserError('Nincs eszközkapcsolat.');
          }
          result = d.command(object(c['command']), simulation.now);
          break;
        case 'control':
          final command = object(c['command']);
          simulation.control(command);
          for (final d in simulation.devices) {
            if (!d.online ||
                (command['device_id'] == d.id && command['reboot'] == true)) {
              _disconnect(d.id);
            }
          }
          result = simulation.state;
          _send({'type': 'simulator', 'state': result});
          break;
        default:
          throw const UserError('Ismeretlen kérés');
      }
      _send({'id': id, 'ok': true, 'result': result});
    } catch (e) {
      if (id == null) {
        unawaited(socket.close(WebSocketStatus.policyViolation));
      } else {
        _send({
          'id': id,
          'ok': false,
          'error': e is UserError ? e.message : 'Hibás szimulátorkérés',
        });
      }
    }
  }

  void _tick() {
    simulation.advance();
    final now = simulation.now;
    for (final d in simulation.devices) {
      final packet = d.sample(now, simulation.terrain);
      if (_connected.contains(d.id) && d.online) {
        _send({
          'type': 'packet',
          'device_id': d.id,
          'data': base64.encode(packet),
        });
      }
    }
    if (now - _lastGps >= 1000) {
      _lastGps = now;
      if (simulation.gps) _send({'type': 'gps', 'fix': simulation.fix()});
      _send({'type': 'simulator', 'state': simulation.state});
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    await _server?.close(force: true);
  }
}
