import 'package:flutter/material.dart';
import '../controller.dart';
import '../core/model.dart';
import 'common.dart';

class SimulatorPanel extends StatefulWidget {
  final AppController app;
  const SimulatorPanel(this.app, {super.key});
  @override
  State<SimulatorPanel> createState() => _SimulatorPanelState();
}

class _SimulatorPanelState extends State<SimulatorPanel> {
  bool busy = false;
  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    await guard(context, work);
    if (mounted) setState(() => busy = false);
  }

  void control(Json command) => run(() async {
    await widget.app.capture.command('simulator', command);
    widget.app.changed();
  });
  @override
  Widget build(BuildContext context) {
    final app = widget.app, state = app.capture.state['simulator'] as Map?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Szimulátor', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Két érzékelő, 10 Hz, 10 km/h. A nyomás és a GPS mesterséges. Fiókkal a tesztmérés a service-be is feltöltődik.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: busy || app.recording
                      ? null
                      : () => run(app.prepareSimulation),
                  icon: const Icon(Icons.science_outlined),
                  label: Text(
                    app.rig == null
                        ? 'Tesztpár előkészítése'
                        : 'Tesztpár csatlakoztatása',
                  ),
                ),
                if (state != null) ...[
                  FilterChip(
                    label: const Text('GPS'),
                    selected: state['gps'] == true,
                    onSelected: busy
                        ? null
                        : (v) => control({'action': 'gps', 'enabled': v}),
                  ),
                  FilterChip(
                    label: const Text('Traktor halad'),
                    selected: state['moving'] == true,
                    onSelected: busy
                        ? null
                        : (v) => control({'action': 'moving', 'enabled': v}),
                  ),
                ],
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            for (final d in objects(state?['devices'])) ...[
              const Divider(height: 28),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${d['role']} · ${shortId(d['id'])}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  FilterChip(
                    label: const Text('Elérhető'),
                    selected: d['online'] == true,
                    onSelected: busy
                        ? null
                        : (v) => control({
                            'action': 'device',
                            'device_id': d['id'],
                            'online': v,
                          }),
                  ),
                  FilterChip(
                    label: const Text('Szenzorhiba'),
                    selected: d['sensor_error'] == true,
                    onSelected: busy
                        ? null
                        : (v) => control({
                            'action': 'device',
                            'device_id': d['id'],
                            'sensor_error': v,
                          }),
                  ),
                  DropdownButton<double>(
                    hint: const Text('Változó nyomás'),
                    value: (d['pressure_bar'] as num?)?.toDouble(),
                    items: [
                      const DropdownMenuItem<double>(
                        value: null,
                        child: Text('Változó nyomás'),
                      ),
                      for (final bar in [0.0, 50.0, 100.0, 150.0, 200.0])
                        DropdownMenuItem(
                          value: bar,
                          child: Text('${bar.round()} bar'),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => control({
                            'action': 'device',
                            'device_id': d['id'],
                            'pressure_bar': v,
                          }),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => control({
                            'action': 'device',
                            'device_id': d['id'],
                            'reboot': true,
                          }),
                    child: const Text('Újraindítás'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
