import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

/// Stato vuoto illustrato, nello stesso tono di quello del diario: un fondo
/// verde tenue, un'icona nel suo riquadro e una frase che dice cosa fare, mai
/// «nessun dato».
///
/// Il fondo non è un colore fisso ma il `primaryContainer` steso al 45% sopra
/// la superficie: così vale identico di giorno e di notte senza una seconda
/// tavolozza da tenere allineata.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    required this.message,
    this.title,
    this.icon = Icons.eco_rounded,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    super.key,
  }) : assert(
         (actionLabel == null) == (onAction == null),
         'Etichetta e azione vanno insieme.',
       );

  /// Cosa succede o cosa fare. Una frase, in italiano, non un'etichetta.
  final String message;

  /// Titolo breve, solo nella versione estesa.
  final String? title;

  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Versione a una riga, per stare dentro una card già piena.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final background = Color.alphaBlend(
      theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
      theme.colorScheme.surface,
    );
    final border = theme.colorScheme.primaryContainer;

    // Un solo nodo semantico: chi usa il lettore di schermo sente la frase,
    // non «icona, titolo, testo».
    return Semantics(
      container: true,
      label: [title, message].nonNulls.join('. '),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: border),
        ),
        child: Padding(
          padding: EdgeInsets.all(compact ? 16 : 24),
          child: compact
              ? _CompactBody(icon: icon, message: message)
              : _FullBody(
                  icon: icon,
                  title: title,
                  message: message,
                  actionLabel: actionLabel,
                  onAction: onAction,
                  accents: accents,
                ),
        ),
      ),
    );
  }
}

class _CompactBody extends StatelessWidget {
  const _CompactBody({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: Row(
        children: [
          _IconTile(icon: icon, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullBody extends StatelessWidget {
  const _FullBody({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.accents,
  });

  final IconData icon;
  final String? title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final AppAccents accents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _IconTile(icon: icon, size: 68),
              const SizedBox(height: 14),
              if (title case final title?) ...[
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.mutedInk,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (actionLabel case final label?) ...[
          const SizedBox(height: 16),
          // Contornato e non pieno: da uno stato vuoto si esce, ma non è
          // l'azione principale della schermata.
          OutlinedButton(onPressed: onAction, child: Text(label)),
        ],
      ],
    );
  }
}

/// Il riquadro chiaro dietro l'icona: è l'elemento che rende «illustrato»
/// lo stato vuoto senza tirarci dentro un'immagine da mantenere.
class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(size / 3),
      ),
      child: Icon(icon, color: scheme.primary, size: size * 0.55),
    );
  }
}
