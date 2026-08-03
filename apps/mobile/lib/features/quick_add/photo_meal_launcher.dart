import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/sync/sync_auth.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_gateway.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_pipeline.dart';

/// Flusso condiviso «fotografa il pasto»: guard sull'accesso cloud, scelta
/// della sorgente (camera o galleria) e accodamento del job. Lo usano il
/// pulsante sotto ogni pasto del diario e il menu smart del FAB, che prima
/// chiede a Marco il pasto. Mai un crash offline: solo messaggi gentili.
Future<void> startPhotoMealCapture({
  required BuildContext context,
  required WidgetRef ref,
  required MealType mealType,
  required DateTime day,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!ref.read(syncAuthProvider).signedIn) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Per fotografare il pasto serve l’accesso al cloud: vai in '
          'Progressi → Sincronizzazione e accedi.',
        ),
      ),
    );
    return;
  }
  final source = await showModalBottomSheet<PhotoMealSource>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('photo_source_camera'),
            leading: const Icon(Icons.photo_camera_rounded),
            title: const Text('Scatta una foto'),
            onTap: () => Navigator.pop(context, PhotoMealSource.camera),
          ),
          ListTile(
            key: const Key('photo_source_gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Scegli dalla galleria'),
            onTap: () => Navigator.pop(context, PhotoMealSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) {
    return;
  }
  try {
    final profile = await ref.read(marcoProfileProvider.future);
    final job = await ref
        .read(photoMealJobsProvider.notifier)
        .capture(
          source: source,
          profileId: profile.id,
          mealType: mealType,
          day: day,
        );
    if (job != null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Foto inviata: l’analisi parte appena il Mac è disponibile. '
            'Nel frattempo puoi sempre aggiungere a mano.',
          ),
        ),
      );
    }
  } on PhotoMealException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } on PhotoPipelineException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } on Object {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Non riesco a inviare la foto: riprova tra poco.'),
      ),
    );
  }
}
