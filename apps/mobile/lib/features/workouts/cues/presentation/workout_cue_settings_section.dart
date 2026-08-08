import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';

/// Preferenze comprensibili senza conoscere TTS, audio focus o wake-lock.
class WorkoutCueSettingsSection extends StatelessWidget {
  const WorkoutCueSettingsSection({
    required this.preferences,
    required this.onChanged,
    this.onTestVoice,
    this.notificationsAvailable = true,
    super.key,
  });

  final WorkoutCuePreferences preferences;
  final ValueChanged<WorkoutCuePreferences> onChanged;
  final VoidCallback? onTestVoice;
  final bool notificationsAvailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return SectionCard(
      key: const Key('workout_cue_settings'),
      title: 'Guida durante l’allenamento',
      subtitle: 'Voce, segnali e comportamento del telefono',
      icon: Icons.record_voice_over_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Voce',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final level in VoiceGuidanceLevel.values)
                ChoiceChip(
                  key: Key('voice_level_${level.name}'),
                  selected: preferences.voice == level,
                  label: Text(_voiceLabel(level)),
                  onSelected: (_) =>
                      onChanged(preferences.copyWith(voice: level)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _voiceExplanation(preferences.voice),
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          if (preferences.voice != VoiceGuidanceLevel.off &&
              onTestVoice != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('workout_test_voice'),
                onPressed: onTestVoice,
                icon: const Icon(Icons.volume_up_rounded),
                label: const Text('Prova la voce'),
              ),
            ),
          ],
          const Divider(height: 24),
          _SettingSwitch(
            key: const Key('workout_countdown_toggle'),
            title: 'Conto alla rovescia',
            subtitle: 'Avvisa a 10 secondi e negli ultimi 3.',
            value: preferences.countdownEnabled,
            onChanged: (value) =>
                onChanged(preferences.copyWith(countdownEnabled: value)),
          ),
          _SettingSwitch(
            key: const Key('workout_beeps_toggle'),
            title: 'Suoni brevi',
            subtitle: 'Un segnale riconoscibile anche senza voce.',
            value: preferences.beepsEnabled,
            onChanged: (value) =>
                onChanged(preferences.copyWith(beepsEnabled: value)),
          ),
          _SettingSwitch(
            key: const Key('workout_haptics_toggle'),
            title: 'Vibrazione',
            subtitle: 'Conferma serie, cambi e fine recupero.',
            value: preferences.hapticsEnabled,
            onChanged: (value) =>
                onChanged(preferences.copyWith(hapticsEnabled: value)),
          ),
          _SettingSwitch(
            key: const Key('workout_notifications_toggle'),
            title: 'Avvisi a schermo spento',
            subtitle: notificationsAvailable
                ? 'Il telefono avvisa quando termina il recupero.'
                : 'Non disponibili su questo dispositivo.',
            value: notificationsAvailable && preferences.notificationsEnabled,
            onChanged: notificationsAvailable
                ? (value) => onChanged(
                    preferences.copyWith(notificationsEnabled: value),
                  )
                : null,
          ),
          _SettingSwitch(
            key: const Key('workout_awake_toggle'),
            title: 'Schermo sempre acceso',
            subtitle: 'Solo mentre una sessione è aperta.',
            value: preferences.keepScreenAwake,
            onChanged: (value) =>
                onChanged(preferences.copyWith(keepScreenAwake: value)),
          ),
          if (preferences.voice != VoiceGuidanceLevel.off)
            _SettingSwitch(
              key: const Key('workout_duck_audio_toggle'),
              title: 'Abbassa la musica mentre parla',
              subtitle: 'La musica riprende subito dopo il messaggio.',
              value: preferences.duckOtherAudio,
              onChanged: (value) =>
                  onChanged(preferences.copyWith(duckOtherAudio: value)),
            ),
        ],
      ),
    );
  }
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: onChanged,
  );
}

String _voiceLabel(VoiceGuidanceLevel level) => switch (level) {
  VoiceGuidanceLevel.off => 'Spenta',
  VoiceGuidanceLevel.essential => 'Essenziale',
  VoiceGuidanceLevel.detailed => 'Dettagliata',
};

String _voiceExplanation(VoiceGuidanceLevel level) => switch (level) {
  VoiceGuidanceLevel.off => 'Nessun messaggio parlato.',
  VoiceGuidanceLevel.essential =>
    'Parla nei cambi importanti: esercizio, fine recupero, record e fine.',
  VoiceGuidanceLevel.detailed =>
    'Aggiunge serie completate, inizio recupero e conto alla rovescia.',
};
