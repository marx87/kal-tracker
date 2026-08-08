import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';

/// Quanta voce vuole sentire Marco durante una sessione.
enum VoiceGuidanceLevel {
  /// Nessuna frase. Vibrazioni, beep e notifiche restano indipendenti.
  off,

  /// Solo cambi esercizio/fase, fine recupero, record e fine sessione.
  essential,

  /// Include serie completate, inizio recupero e countdown configurato.
  detailed,
}

/// Preferenze indipendenti dalla schermata che sta conducendo la sessione.
@immutable
class WorkoutCuePreferences {
  const WorkoutCuePreferences({
    this.voice = VoiceGuidanceLevel.essential,
    this.countdownEnabled = true,
    this.countdownSeconds = const {10, 5, 3, 2, 1},
    this.beepsEnabled = true,
    this.hapticsEnabled = true,
    this.notificationsEnabled = true,
    this.keepScreenAwake = false,
    this.duckOtherAudio = true,
    this.allowBluetoothOutput = true,
    this.languageTag = 'it-IT',
    this.speechRate = 0.48,
    this.speechVolume = 1,
    this.speechPitch = 1,
  }) : assert(speechRate >= 0 && speechRate <= 1),
       assert(speechVolume >= 0 && speechVolume <= 1),
       assert(speechPitch >= 0.5 && speechPitch <= 2);

  final VoiceGuidanceLevel voice;
  final bool countdownEnabled;
  final Set<int> countdownSeconds;
  final bool beepsEnabled;
  final bool hapticsEnabled;
  final bool notificationsEnabled;
  final bool keepScreenAwake;

  /// Chiede un audio focus transitorio: musica più bassa, non interrotta.
  final bool duckOtherAudio;

  /// Consente al sistema di conservare cuffie/Bluetooth come uscita.
  /// Non forza una rotta che l'utente non ha selezionato.
  final bool allowBluetoothOutput;

  final String languageTag;
  final double speechRate;
  final double speechVolume;
  final double speechPitch;

  bool shouldSpeak(WorkoutCue cue) => switch (voice) {
    VoiceGuidanceLevel.off => false,
    VoiceGuidanceLevel.essential =>
      cue.importance.index >= WorkoutCueImportance.essential.index,
    VoiceGuidanceLevel.detailed => true,
  };

  WorkoutCuePreferences copyWith({
    VoiceGuidanceLevel? voice,
    bool? countdownEnabled,
    Set<int>? countdownSeconds,
    bool? beepsEnabled,
    bool? hapticsEnabled,
    bool? notificationsEnabled,
    bool? keepScreenAwake,
    bool? duckOtherAudio,
    bool? allowBluetoothOutput,
    String? languageTag,
    double? speechRate,
    double? speechVolume,
    double? speechPitch,
  }) => WorkoutCuePreferences(
    voice: voice ?? this.voice,
    countdownEnabled: countdownEnabled ?? this.countdownEnabled,
    countdownSeconds: countdownSeconds ?? this.countdownSeconds,
    beepsEnabled: beepsEnabled ?? this.beepsEnabled,
    hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
    duckOtherAudio: duckOtherAudio ?? this.duckOtherAudio,
    allowBluetoothOutput: allowBluetoothOutput ?? this.allowBluetoothOutput,
    languageTag: languageTag ?? this.languageTag,
    speechRate: speechRate ?? this.speechRate,
    speechVolume: speechVolume ?? this.speechVolume,
    speechPitch: speechPitch ?? this.speechPitch,
  );

  Map<String, Object?> toJson() => {
    'voice': voice.name,
    'countdown_enabled': countdownEnabled,
    'countdown_seconds': countdownSeconds.toList()..sort((a, b) => b - a),
    'beeps_enabled': beepsEnabled,
    'haptics_enabled': hapticsEnabled,
    'notifications_enabled': notificationsEnabled,
    'keep_screen_awake': keepScreenAwake,
    'duck_other_audio': duckOtherAudio,
    'allow_bluetooth_output': allowBluetoothOutput,
    'language_tag': languageTag,
    'speech_rate': speechRate,
    'speech_volume': speechVolume,
    'speech_pitch': speechPitch,
  };

  factory WorkoutCuePreferences.fromJson(Object? value) {
    if (value is! Map) return const WorkoutCuePreferences();
    final json = value.cast<String, Object?>();
    final countdown = switch (json['countdown_seconds']) {
      final List values =>
        values
            .whereType<num>()
            .map((item) => item.toInt())
            .where((item) => item > 0 && item <= 60)
            .toSet(),
      _ => const <int>{10, 5, 3, 2, 1},
    };
    return WorkoutCuePreferences(
      voice: VoiceGuidanceLevel.values.firstWhere(
        (level) => level.name == json['voice'],
        orElse: () => VoiceGuidanceLevel.essential,
      ),
      countdownEnabled: json['countdown_enabled'] as bool? ?? true,
      countdownSeconds: countdown,
      beepsEnabled: json['beeps_enabled'] as bool? ?? true,
      hapticsEnabled: json['haptics_enabled'] as bool? ?? true,
      notificationsEnabled: json['notifications_enabled'] as bool? ?? true,
      keepScreenAwake: json['keep_screen_awake'] as bool? ?? false,
      duckOtherAudio: json['duck_other_audio'] as bool? ?? true,
      allowBluetoothOutput: json['allow_bluetooth_output'] as bool? ?? true,
      languageTag: json['language_tag'] as String? ?? 'it-IT',
      speechRate: _unitValue(json['speech_rate'], 0.48),
      speechVolume: _unitValue(json['speech_volume'], 1),
      speechPitch: _pitchValue(json['speech_pitch']),
    );
  }
}

double _unitValue(Object? value, double fallback) {
  if (value is! num) return fallback;
  return value.toDouble().clamp(0, 1);
}

double _pitchValue(Object? value) {
  if (value is! num) return 1;
  return value.toDouble().clamp(0.5, 2);
}
