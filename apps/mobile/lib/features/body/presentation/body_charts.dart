import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/body/presentation/body_formats.dart';

/// Grafici della schermata Corpo, disegnati a mano.
///
/// `fl_chart` è già in uso in Gym Tracker ma NON è tra le dipendenze di Kal
/// (vedi pubspec.yaml): finché non ci entra, qui si dipinge con
/// `CustomPainter`. Nessun colore letterale: tutto arriva dal tema, così i
/// grafici seguono chiaro e scuro senza una seconda tavolozza.

/// Le due aree impilate: kg di massa grassa in basso, kg di massa magra
/// sopra. La somma è il peso delle pesate con impedenza.
///
/// È il grafico principale perché è l'unico che risponde alla domanda vera:
/// una linea del peso che scende non dice se stai perdendo grasso o muscolo,
/// due bande che si muovono in direzioni opposte sì.
///
/// L'asse parte da zero, come deve fare una pila: le proporzioni sono oneste
/// e la linea di confine tra le due bande è il grasso. Il *dettaglio* del
/// cambiamento — che a scala piena resta di pochi pixel — lo mostrano i due
/// grafici zoomati [BodyZoomChart] e i numeri accanto.
class BodyCompositionChart extends StatelessWidget {
  const BodyCompositionChart({required this.points, super.key});

  /// Punti della media mobile a 7 giorni che hanno composizione, in ordine
  /// cronologico. Servono almeno due punti.
  final List<BodyTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final first = points.first;
    final last = points.last;

    return Semantics(
      container: true,
      label: 'Grafico ad aree impilate della composizione corporea',
      value:
          'Dal ${BodyFormats.longDay(first.day)} al '
          '${BodyFormats.longDay(last.day)}. '
          'Massa grassa da ${BodyFormats.spokenKg(first.fatMassKg!)} a '
          '${BodyFormats.spokenKg(last.fatMassKg!)}. '
          'Massa magra da ${BodyFormats.spokenKg(first.leanMassKg!)} a '
          '${BodyFormats.spokenKg(last.leanMassKg!)}.',
      child: ExcludeSemantics(
        child: CustomPaint(
          size: Size.infinite,
          painter: _StackedCompositionPainter(
            points: points,
            fatColor: theme.colorScheme.secondary,
            leanColor: theme.colorScheme.primary,
            gridColor: theme.colorScheme.outline,
            labelStyle:
                theme.textTheme.labelSmall?.copyWith(color: accents.mutedInk) ??
                TextStyle(color: accents.mutedInk, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

/// Una sola serie, con l'asse tagliato attorno ai suoi valori: è qui che si
/// vede il movimento che nella pila a scala piena vale due pixel.
///
/// L'asse tagliato è dichiarato a schermo (minimo e massimo scritti
/// sull'asse) perché un grafico zoomato senza etichette è un grafico che
/// mente.
class BodyZoomChart extends StatelessWidget {
  const BodyZoomChart({
    required this.title,
    required this.points,
    required this.color,
    this.unit = 'kg',
    this.semanticsUnit = 'chilogrammi',
    super.key,
  });

  final String title;

  /// Coppie giorno/valore in ordine cronologico. Servono almeno due punti.
  final List<(DateTime, double)> points;

  final Color color;

  /// Unità scritta sull'asse: «kg» per le masse, «cm» per il metro.
  final String unit;

  /// Come si legge l'unità ad alta voce.
  final String semanticsUnit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final values = points.map((point) => point.$2).toList(growable: false);
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);

    return Semantics(
      container: true,
      label: '$title, andamento delle medie a 7 giorni',
      value:
          'Da ${BodyFormats.spokenNumber(values.first)} a '
          '${BodyFormats.spokenNumber(values.last)} $semanticsUnit. '
          'Asse da ${BodyFormats.spokenNumber(minimum)} a '
          '${BodyFormats.spokenNumber(maximum)}.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 74,
              child: CustomPaint(
                size: Size.infinite,
                painter: _ZoomSeriesPainter(
                  points: points,
                  color: color,
                  gridColor: theme.colorScheme.outline,
                  labelStyle:
                      theme.textTheme.labelSmall?.copyWith(
                        color: accents.mutedInk,
                      ) ??
                      TextStyle(color: accents.mutedInk, fontSize: 11),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              // Detto a parole: l'asse non parte da zero, e chi guarda deve
              // saperlo prima di stimare l'ampiezza del movimento.
              'Asse tagliato: ${BodyFormats.kg(minimum)}–'
              '${BodyFormats.kg(maximum)} $unit',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StackedCompositionPainter extends CustomPainter {
  _StackedCompositionPainter({
    required this.points,
    required this.fatColor,
    required this.leanColor,
    required this.gridColor,
    required this.labelStyle,
  });

  final List<BodyTrendPoint> points;
  final Color fatColor;
  final Color leanColor;
  final Color gridColor;
  final TextStyle labelStyle;

  static const _leftGutter = 42.0;
  static const _bottomGutter = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTRB(
      _leftGutter,
      6,
      math.max(_leftGutter + 1, size.width - 6),
      math.max(7, size.height - _bottomGutter),
    );
    if (points.length < 2 || chart.width <= 0 || chart.height <= 0) {
      return;
    }

    final totals = points
        .map((point) => point.compositionWeightKg!)
        .toList(growable: false);
    // Il 6% di aria in cima evita che la linea del peso tocchi il bordo.
    final maximum = totals.reduce(math.max) * 1.06;
    final firstDay = points.first.day;
    final spanDays = math.max(1, points.last.day.difference(firstDay).inDays);

    double dx(DateTime day) =>
        chart.left + chart.width * (day.difference(firstDay).inDays / spanDays);
    double dy(double kg) => chart.bottom - chart.height * (kg / maximum);

    _paintGrid(canvas, chart, maximum);

    final fatTop = <Offset>[];
    final total = <Offset>[];
    for (final point in points) {
      final x = dx(point.day);
      fatTop.add(Offset(x, dy(point.fatMassKg!)));
      total.add(Offset(x, dy(point.compositionWeightKg!)));
    }

    // Banda della massa grassa: da zero alla linea di confine.
    _fillBand(
      canvas,
      lower: [
        Offset(chart.left, chart.bottom),
        Offset(chart.right, chart.bottom),
      ],
      upper: fatTop,
      color: fatColor.withValues(alpha: 0.55),
    );
    // Banda della massa magra: dal confine al peso totale.
    _fillBand(
      canvas,
      lower: fatTop,
      upper: total,
      color: leanColor.withValues(alpha: 0.45),
    );

    // Il confine è la massa grassa: è la linea che conta, quindi è quella
    // disegnata più spessa.
    _stroke(canvas, fatTop, fatColor, 2.6);
    _stroke(canvas, total, leanColor, 2);

    final marker = Paint()..color = leanColor;
    canvas.drawCircle(total.last, 3.5, marker);
    canvas.drawCircle(fatTop.last, 3.5, Paint()..color = fatColor);

    _paintDayLabels(canvas, chart, points.first.day, points.last.day);
  }

  void _paintGrid(Canvas canvas, Rect chart, double maximum) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.8;
    const lines = 4;
    for (var index = 0; index < lines; index++) {
      final value = maximum * index / (lines - 1);
      final y = chart.bottom - chart.height * (value / maximum);
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), paint);
      final label = _text('${value.round()}');
      label.paint(
        canvas,
        Offset(chart.left - label.width - 6, y - label.height / 2),
      );
    }
  }

  void _paintDayLabels(Canvas canvas, Rect chart, DateTime from, DateTime to) {
    final start = _text(BodyFormats.shortDay(from));
    start.paint(canvas, Offset(chart.left, chart.bottom + 4));
    final end = _text(BodyFormats.shortDay(to));
    end.paint(canvas, Offset(chart.right - end.width, chart.bottom + 4));
  }

  TextPainter _text(String value) => TextPainter(
    text: TextSpan(text: value, style: labelStyle),
    textDirection: TextDirection.ltr,
  )..layout();

  void _fillBand(
    Canvas canvas, {
    required List<Offset> lower,
    required List<Offset> upper,
    required Color color,
  }) {
    final path = Path()..moveTo(upper.first.dx, upper.first.dy);
    for (final point in upper.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    for (final point in lower.reversed) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _stroke(Canvas canvas, List<Offset> line, Color color, double width) {
    final path = Path()..moveTo(line.first.dx, line.first.dy);
    for (final point in line.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _StackedCompositionPainter oldDelegate) =>
      !identical(oldDelegate.points, points) ||
      oldDelegate.fatColor != fatColor ||
      oldDelegate.leanColor != leanColor ||
      oldDelegate.gridColor != gridColor;
}

class _ZoomSeriesPainter extends CustomPainter {
  _ZoomSeriesPainter({
    required this.points,
    required this.color,
    required this.gridColor,
    required this.labelStyle,
  });

  final List<(DateTime, double)> points;
  final Color color;
  final Color gridColor;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTRB(
      0,
      6,
      math.max(1, size.width),
      math.max(7, size.height - 2),
    );
    if (points.length < 2) {
      return;
    }

    final values = points.map((point) => point.$2).toList(growable: false);
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    // Con una serie piatta il range sarebbe zero: si apre di mezzo chilo,
    // così la linea resta al centro invece di dividere per zero.
    final range = math.max(0.5, maximum - minimum);
    final firstDay = points.first.$1;
    final spanDays = math.max(1, points.last.$1.difference(firstDay).inDays);

    final line = <Offset>[
      for (final point in points)
        Offset(
          chart.left +
              chart.width * (point.$1.difference(firstDay).inDays / spanDays),
          chart.bottom - chart.height * ((point.$2 - minimum) / range),
        ),
    ];

    final baseline = Paint()
      ..color = gridColor
      ..strokeWidth = 0.8;
    canvas.drawLine(
      Offset(chart.left, chart.bottom),
      Offset(chart.right, chart.bottom),
      baseline,
    );

    final area = Path()..moveTo(line.first.dx, chart.bottom);
    for (final point in line) {
      area.lineTo(point.dx, point.dy);
    }
    area
      ..lineTo(line.last.dx, chart.bottom)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.18));

    final path = Path()..moveTo(line.first.dx, line.first.dy);
    for (final point in line.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(line.last, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ZoomSeriesPainter oldDelegate) =>
      !identical(oldDelegate.points, points) ||
      oldDelegate.color != color ||
      oldDelegate.gridColor != gridColor;
}
