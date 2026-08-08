import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/coach/domain/coach_feed_item.dart';
import 'package:kal_tracker/features/coach/presentation/coach_feed_providers.dart';

/// L'ultimo aggiornamento del Coach, in forma compatta per Oggi.
///
/// Caricamento ed errori restano silenziosi: il diario deve continuare a
/// funzionare anche se il feed non è disponibile.
class CoachFeed extends ConsumerWidget {
  const CoachFeed({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(coachFeedProvider).valueOrNull;
    if (items == null || items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: _CoachFeedCard(item: items.first),
    );
  }
}

class _CoachFeedCard extends ConsumerWidget {
  const _CoachFeedCard({required this.item});

  final CoachFeedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accents = AppAccents.of(context);
    final actionPath = item.actionPath;
    return Semantics(
      container: true,
      label: item.isRead
          ? 'Aggiornamento del Coach'
          : 'Nuovo aggiornamento del Coach',
      child: SectionCard(
        key: const Key('coach_feed_card'),
        title: item.title,
        subtitle: item.source == CoachFeedSource.ai
            ? 'Dal commento del Coach'
            : 'Dal Coach',
        icon: Icons.auto_awesome_rounded,
        actionLabel: 'Nascondi',
        onAction: () =>
            unawaited(ref.read(coachFeedActionsProvider).dismiss(item.id)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              item.body,
              key: const Key('coach_feed_body'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: accents.mutedInk),
            ),
            if (actionPath != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('coach_feed_action'),
                  onPressed: () => unawaited(_open(context, ref, actionPath)),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(item.actionLabel ?? 'Apri'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    String actionPath,
  ) async {
    await ref.read(coachFeedActionsProvider).markRead(item.id);
    if (context.mounted) {
      GoRouter.of(context).go(actionPath);
    }
  }
}
