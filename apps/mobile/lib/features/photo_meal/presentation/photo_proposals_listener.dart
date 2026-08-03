import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_providers.dart';

/// Avvolge la shell dell'app: tiene aggiornato [photoForegroundProvider]
/// con il ciclo di vita (il polling tace in background) e mostra la
/// notifica in-app "Proposta pronta da rivedere" quando un job foto
/// arriva in needs_review con un risultato valido.
class PhotoProposalsListener extends ConsumerStatefulWidget {
  const PhotoProposalsListener({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PhotoProposalsListener> createState() =>
      _PhotoProposalsListenerState();
}

class _PhotoProposalsListenerState
    extends ConsumerState<PhotoProposalsListener> {
  AppLifecycleListener? _lifecycle;
  final Set<String> _notifiedJobIds = {};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        ref.read(photoForegroundProvider.notifier).state =
            state == AppLifecycleState.resumed;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<PhotoMealJob>>(photoProposalsReadyProvider, (
      previous,
      next,
    ) {
      for (final job in next) {
        if (_notifiedJobIds.add(job.id)) {
          _showProposalReady(job);
        }
      }
    });
    return widget.child;
  }

  void _showProposalReady(PhotoMealJob job) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        key: Key('photo_proposal_ready_${job.id}'),
        duration: const Duration(seconds: 8),
        content: const Text('Proposta pronta da rivedere: foto analizzata.'),
        action: SnackBarAction(
          label: 'Rivedi',
          onPressed: () => GoRouter.of(context).push('/photo-review/${job.id}'),
        ),
      ),
    );
  }
}

/// Badge riutilizzabile da mostrare vicino ai pasti: appare solo quando
/// c'è almeno una proposta pronta e porta alla schermata di revisione.
class PhotoProposalsBadge extends ConsumerWidget {
  const PhotoProposalsBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(photoProposalsReadyProvider);
    if (ready.isEmpty) {
      return const SizedBox.shrink();
    }
    final label = ready.length == 1
        ? 'Proposta pronta da rivedere'
        : '${ready.length} proposte pronte da rivedere';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        key: const Key('photo_proposals_badge'),
        color: AppPalette.yellowSoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () =>
              GoRouter.of(context).push('/photo-review/${ready.first.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: AppPalette.forestDark,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: AppPalette.forestDark,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
