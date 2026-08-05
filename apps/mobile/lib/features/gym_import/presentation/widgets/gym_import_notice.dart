import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';

/// Il tono di un avviso dell'import.
///
/// Non riuso [AppStatusLevel] perché qui serve anche l'«informativo», che nel
/// design system esiste come coppia di colori ([AppAccents.info]) ma non come
/// livello di stato: un elenco di campi non importati non è un problema, è
/// una cosa da sapere.
enum GymImportNoticeTone {
  info,
  warning,
  critical;

  Color foreground(AppAccents accents) => switch (this) {
    GymImportNoticeTone.info => accents.info,
    GymImportNoticeTone.warning => accents.warning,
    GymImportNoticeTone.critical => accents.critical,
  };

  Color background(AppAccents accents) => switch (this) {
    GymImportNoticeTone.info => accents.infoSurface,
    GymImportNoticeTone.warning => accents.warningSurface,
    GymImportNoticeTone.critical => accents.criticalSurface,
  };
}

/// Riquadro d'avviso: icona, titolo e o un paragrafo o un elenco.
///
/// Il significato non è affidato al colore: l'icona cambia forma e il titolo
/// dice a parole di cosa si tratta. È lo stesso patto di `StatusChip`, ma per
/// un blocco di testo lungo — le pastiglie non reggono tre righe di avviso.
class GymImportNotice extends StatelessWidget {
  const GymImportNotice({
    required this.icon,
    required this.title,
    required this.tone,
    this.message,
    this.lines = const [],
    super.key,
  });

  final IconData icon;
  final String title;
  final GymImportNoticeTone tone;

  /// Il testo dell'avviso, quando è uno solo.
  final String? message;

  /// Le voci, quando sono un elenco (avvisi dell'import, campi non accolti).
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final foreground = tone.foreground(accents);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.background(accents),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: foreground.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (message case final message?) ...[
              const SizedBox(height: 6),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  height: 1.4,
                ),
              ),
            ],
            for (final line in lines) ...[
              const SizedBox(height: 8),
              _NoticeLine(text: line, bullet: foreground),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.text, required this.bullet});

  final String text;
  final Color bullet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Il pallino è decorazione: allineato alla prima riga di testo e
        // tolto dalla semantica, così il lettore di schermo legge la frase.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: bullet, shape: BoxShape.circle),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
