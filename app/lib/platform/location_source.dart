import 'dart:async';
import 'dart:io';
import 'package:geolocator/geolocator.dart';
import '../core/model.dart';

/// Optional input: unavailable location never stops pressure capture.
class LocationSource {
  StreamSubscription<Position>? _subscription;
  int _generation = 0;
  bool get running => _subscription != null;
  Future<bool> start(
    void Function(Json) fix,
    void Function(String) status, {
    bool request = true,
  }) async {
    final generation = _generation;
    if (!const bool.fromEnvironment('HAS_GPS', defaultValue: true)) {
      return false;
    }
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && request) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        status('Nincs helyengedély · a nyomásadatok rögzülnek');
        return false;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        status('GPS kikapcsolva · a nyomásadatok rögzülnek');
        return true;
      }
      if (generation != _generation) return false;
      if (running) return true;
      final settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 1),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
            );
      _subscription = Geolocator.getPositionStream(locationSettings: settings)
          .listen(
            (p) {
              if (!p.latitude.isFinite ||
                  !p.longitude.isFinite ||
                  !p.accuracy.isFinite ||
                  p.accuracy < 0) {
                return;
              }
              fix({
                'id': ids.v4(),
                'captured_at': p.timestamp.toUtc().toIso8601String(),
                'latitude': p.latitude,
                'longitude': p.longitude,
                'accuracy_m': p.accuracy,
                'speed_mps': p.speed >= 0 && p.speed.isFinite ? p.speed : null,
                'heading_deg': p.heading >= 0 && p.heading.isFinite
                    ? p.heading
                    : null,
              });
            },
            onError: (Object error) {
              status('GPS nem elérhető · a nyomásadatok rögzülnek');
              unawaited(stop());
            },
          );
      return true;
    } catch (_) {
      status('GPS nem elérhető · a nyomásadatok rögzülnek');
      return false;
    }
  }

  Future<void> stop() async {
    _generation++;
    final s = _subscription;
    _subscription = null;
    await s?.cancel();
  }
}
