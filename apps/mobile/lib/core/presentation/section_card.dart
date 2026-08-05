import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

/// La card con cui si apre una sezione: titolo, sottotitolo facoltativo,
/// un'unica azione a destra e sotto il contenuto.
///
/// L'azione è volutamente `etichetta + callback` e non un widget libero: se
/// ognuno ci mettesse il suo bottone, le sezioni smetterebbero di somigliarsi
/// dopo tre schermate.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.all(18),
    this.background,
    super.key,
  }) : assert(
         (actionLabel == null) == (onAction == null),
         'Etichetta e azione vanno insieme: un bottone senza testo non è '
         'raggiungibile da tastiera né da lettore di schermo.',
       );

  final String title;
  final String? subtitle;

  /// Icona di sezione, nel suo riquadro tenue a sinistra del titolo.
  final IconData? icon;

  final String? actionLabel;
  final VoidCallback? onAction;

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Solo per le sezioni che devono staccarsi (un riepilogo in evidenza).
  /// Lasciato nullo si usa la card di tema.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Card(
      color: background,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon case final icon?) ...[
                  _SectionIcon(icon: icon),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleLarge),
                        if (subtitle case final subtitle?) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: accents.mutedInk,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (actionLabel case final label?) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('section_card_action'),
                    onPressed: onAction,
                    child: Text(label),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Icon(icon, size: 21, color: scheme.onPrimaryContainer),
      ),
    );
  }
}
