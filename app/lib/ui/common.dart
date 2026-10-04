import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../core/model.dart';

const green = Color(0xff17654b),
    blue = Color(0xff3075a8),
    ink = Color(0xff18382e);
String bar(Object? pa) => pa is num ? (pa / 100000).toStringAsFixed(1) : '—';
String date(Object? value) {
  if (value == null) return '—';
  final d = DateTime.tryParse(value.toString())?.toLocal();
  if (d == null) return '—';
  String two(int i) => '$i'.padLeft(2, '0');
  return '${d.year}.${two(d.month)}.${two(d.day)}. ${two(d.hour)}:${two(d.minute)}';
}

Future<T?> guard<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(explain(e)),
          duration: const Duration(seconds: 7),
        ),
      );
    }
    return null;
  }
}

Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  String label = 'Név',
  bool secret = false,
  String? help,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (help != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(help),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: secret,
              maxLength: secret ? null : 120,
              decoration: InputDecoration(labelText: label),
              onSubmitted: (s) => Navigator.pop(context, s),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Mégse'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Rendben'),
        ),
      ],
    ),
  );
  // The dialog's dismissal animation still holds the text controller briefly.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  controller.dispose();
  return result;
}

Future<bool> confirm(BuildContext context, String title, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Mégse'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Megerősítés'),
          ),
        ],
      ),
    ) ??
    false;

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: padding, child: child),
  );
}

class Hint extends StatelessWidget {
  final String text;
  final IconData icon;
  final bool warning;
  const Hint(
    this.text, {
    super.key,
    this.icon = Icons.info_outline,
    this.warning = false,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: warning ? const Color(0xfffff0d2) : const Color(0xffe9f1eb),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: warning ? Colors.brown : green),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class Empty extends StatelessWidget {
  final IconData icon;
  final String title, detail;
  final Widget? action;
  const Empty(this.icon, this.title, this.detail, {super.key, this.action});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: green),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(detail, textAlign: TextAlign.center),
            if (action != null)
              Padding(padding: const EdgeInsets.only(top: 24), child: action!),
          ],
        ),
      ),
    ),
  );
}

class PressureChart extends StatelessWidget {
  final List<List<Json>> series;
  final bool history;
  const PressureChart(this.series, {super.key, this.history = false});
  @override
  Widget build(BuildContext context) {
    final valid = series
        .expand((s) => s)
        .where((p) => p['pa'] != null)
        .toList();
    if (valid.isEmpty) {
      return const SizedBox(
        height: 230,
        child: Empty(
          Icons.show_chart,
          'Még nincs görbe',
          'A csatlakoztatott eszközök nyomásadatai itt jelennek meg.',
        ),
      );
    }
    return Semantics(
      label: 'Nyomásgrafikon, bar. ${valid.length} megjelenített pont.',
      child: SizedBox(
        width: double.infinity,
        height: 250,
        child: CustomPaint(
          painter: _ChartPainter(
            series,
            history,
            Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<List<Json>> series;
  final bool history;
  final String? fontFamily;
  _ChartPainter(this.series, this.history, this.fontFamily);
  void label(
    Canvas c,
    String text,
    Offset at, {
    Color color = const Color(0xff64776e),
  }) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 11, color: color, fontFamily: fontFamily),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pts = series.expand((s) => s).where((p) => p['pa'] != null).toList();
    if (pts.isEmpty) return;
    final left = 44.0,
        right = size.width - 12,
        top = 14.0,
        bottom = size.height - 32;
    var first = pts.map((p) => (p['at'] as num).toDouble()).reduce(math.min),
        last = pts.map((p) => (p['at'] as num).toDouble()).reduce(math.max);
    if (last <= first) last = first + 1000;
    if (!history) first = math.min(first, last - 60000);
    final maximum = math.max(
      20000000.0,
      pts
          .map((p) => ((p['max'] ?? p['pa']) as num).toDouble())
          .reduce(math.max),
    );
    Offset pos(num at, num pa) => Offset(
      left + (at - first) / (last - first) * (right - left),
      bottom - pa / maximum * (bottom - top),
    );
    final grid = Paint()
      ..color = const Color(0xffdce5df)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = bottom - (bottom - top) * i / 4;
      canvas.drawLine(Offset(left, y), Offset(right, y), grid);
      label(
        canvas,
        (maximum * i / 400000).toStringAsFixed(0),
        Offset(2, y - 6),
      );
    }
    label(canvas, 'bar', const Offset(2, 0));
    for (var n = 0; n < series.length; n++) {
      final path = Path();
      int? prev;
      var pen = false;
      final color = n == 0 ? green : blue;
      for (final p in series[n]) {
        final at = p['at'] as int;
        if (p['pa'] == null) {
          pen = false;
          continue;
        }
        final point = pos(at, p['pa'] as num);
        if (!pen || (!history && prev != null && at - prev > 1500)) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
        if (history && p['min'] != null) {
          canvas.drawLine(
            pos(at, p['min']),
            pos(at, p['max']),
            Paint()
              ..color = color.withValues(alpha: .2)
              ..strokeWidth = 2,
          );
        }
        prev = at;
        pen = true;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    String time(double at) {
      final d = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
    }

    label(canvas, time(first), Offset(left, bottom + 10));
    label(canvas, time(last), Offset(math.max(left, right - 50), bottom + 10));
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) => true;
}
