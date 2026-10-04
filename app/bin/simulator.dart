import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:pressure_field/core/model.dart';
import 'package:pressure_field/simulator/engine.dart';
import 'package:pressure_field/simulator/server.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln(
      'pressure_simulator [--headless] [--port=47832] [--profile=default]\n'
      'Ket szenzor + GPS, csak helyi kapcsolat. Vezerles az appban.',
    );
    return;
  }
  final options = <String, String>{};
  for (final arg in arguments) {
    if (arg == '--headless') continue;
    final parts = arg.split('=');
    if (parts.length != 2 || !['--port', '--profile'].contains(parts[0])) {
      stderr.writeln('Ismeretlen kapcsolo: $arg. Segitseg: --help');
      exitCode = 64;
      return;
    }
    options[parts[0]] = parts[1];
  }
  final port = int.tryParse(options['--port'] ?? '$simulatorPort'),
      profile = options['--profile'] ?? 'default';
  if (port == null ||
      port < 1024 ||
      port > 65535 ||
      !RegExp(r'^[a-zA-Z0-9_-]{1,40}$').hasMatch(profile)) {
    stderr.writeln('Ervenytelen port vagy profilnev.');
    exitCode = 64;
    return;
  }
  SimulatorServer? server;
  try {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    final file = File(
      '$base/PressureFieldSimulator/$profile/devices.simulator.json',
    );
    List<Json> registry;
    if (await file.exists()) {
      registry = objects(jsonDecode(await file.readAsString()));
    } else {
      registry = newSimulatorDevices();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(registry),
        flush: true,
      );
    }
    server = SimulatorServer(Simulation(registry));
    await server.start(port: port);
    stdout.writeln(
      'Talajnyomas szimulator · 2 x 10 Hz · 127.0.0.1:$port\n'
      'Service admin-import (titkos, csak tesztkornyezetbe): ${file.path}\n'
      'A vezerlest az app Elo meres lapjan talalod. Leallitas: Ctrl+C.',
    );
    ProcessSignal.sigint.watch().listen((_) async {
      await server?.dispose();
      exit(0);
    });
    if (!arguments.contains('--headless')) {
      final app = File(
        '${File(Platform.resolvedExecutable).parent.path}/pressure_field.exe',
      );
      if (Platform.isWindows && await app.exists()) {
        final process = await Process.start(app.path, [
          '--simulator',
          '--simulator-port=$port',
        ]);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        await process.exitCode;
        await server.dispose();
        exit(0);
      } else {
        stdout.writeln(
          'Inditsd az appot: pressure_field.exe --simulator --simulator-port=$port',
        );
      }
    }
  } catch (e) {
    await server?.dispose();
    stderr.writeln(
      e is SocketException
          ? 'A $port port foglalt. Zard be a masik szimulatort, vagy hasznalj masik portot.'
          : 'A szimulator nem indult el: $e',
    );
    exitCode = 1;
  }
}
