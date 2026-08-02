import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/updates/ota_manifest.dart';
import 'package:kal_tracker/core/updates/update_service.dart';
import 'package:url_launcher/url_launcher.dart';

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(config: ref.watch(appConfigProvider)),
);

final availableUpdateProvider = FutureProvider<AndroidUpdateManifest?>(
  (ref) => ref.watch(updateServiceProvider).checkForUpdate(),
);

class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  double? _progress;
  String? _error;
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) {
      return const SizedBox.shrink();
    }

    final manifest = ref.watch(availableUpdateProvider).value;
    if (manifest == null) {
      return const SizedBox.shrink();
    }

    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update_alt_rounded, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Kal Tracker ${manifest.version} disponibile',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: 'Nascondi',
                  onPressed: () => setState(() => _dismissed = true),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (manifest.notes.isNotEmpty) Text(manifest.notes),
            if (_progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 4),
              Text('Download ${(_progress! * 100).round()}%'),
            ] else ...[
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: colors.error)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _install(manifest),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Aggiorna'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Apri nel browser',
                    onPressed: () => launchUrl(
                      manifest.assetUrl,
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_browser_rounded),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _install(AndroidUpdateManifest manifest) async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      final result = await ref
          .read(updateServiceProvider)
          .downloadAndInstall(
            manifest,
            onProgress: (progress) {
              if (mounted) {
                setState(() => _progress = progress);
              }
            },
          );
      if (mounted) {
        setState(() {
          _progress = null;
          if (!result.installerOpened) {
            _error =
                'APK scaricato. Abilita “Installa app sconosciute” e riprova.';
          }
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = 'Aggiornamento non riuscito: $error';
        });
      }
    }
  }
}
