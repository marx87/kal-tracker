import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_ports.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class FlutterTtsWorkoutSpeechOutput implements WorkoutSpeechOutput {
  FlutterTtsWorkoutSpeechOutput({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<void> configure(WorkoutCuePreferences preferences) async {
    await _tts.setLanguage(preferences.languageTag);
    await _tts.setSpeechRate(preferences.speechRate);
    await _tts.setVolume(preferences.speechVolume);
    await _tts.setPitch(preferences.speechPitch);
    // `speak` deve confermare l'accodamento, non bloccare l'azione workout per
    // tutta la durata della frase.
    await _tts.awaitSpeakCompletion(false);

    if (kIsWeb) return;
    if (Platform.isAndroid) {
      // Usage navigation guidance: Android instrada correttamente verso le
      // cuffie attive e concede un audio focus transitorio quando richiesto.
      await _tts.setAudioAttributesForNavigation();
    } else if (Platform.isIOS) {
      await _tts.setSharedInstance(true);
      await _tts.autoStopSharedSession(true);
      final options = <IosTextToSpeechAudioCategoryOptions>[
        if (preferences.duckOtherAudio) ...[
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions
              .interruptSpokenAudioAndMixWithOthers,
        ] else
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        if (preferences.allowBluetoothOutput) ...[
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ],
      ];
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        options,
        IosTextToSpeechAudioMode.voicePrompt,
      );
    }
  }

  @override
  Future<void> speak(
    String text, {
    required bool interrupt,
    required bool duckOtherAudio,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      // 0 = sostituisci la coda, 1 = aggiungi. Un record o la fine recupero
      // non devono aspettare una frase di dettaglio ormai vecchia.
      await _tts.setQueueMode(interrupt ? 0 : 1);
    } else if (interrupt) {
      await _tts.stop();
    }
    await _tts.speak(text, focus: duckOtherAudio);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}

class SystemWorkoutSignalOutput implements WorkoutSignalOutput {
  const SystemWorkoutSignalOutput();

  @override
  Future<void> play(
    WorkoutCueSignal signal, {
    required bool beep,
    required bool haptic,
  }) async {
    if (beep) {
      // Il click è l'unico suono breve di sistema disponibile su Android e
      // iOS senza introdurre un asset o un secondo motore audio.
      await SystemSound.play(SystemSoundType.click);
    }
    if (!haptic) return;
    switch (signal) {
      case WorkoutCueSignal.selection:
        await HapticFeedback.selectionClick();
      case WorkoutCueSignal.countdown:
        await HapticFeedback.lightImpact();
      case WorkoutCueSignal.transition:
        await HapticFeedback.mediumImpact();
      case WorkoutCueSignal.attention:
      case WorkoutCueSignal.success:
        await HapticFeedback.heavyImpact();
    }
  }
}

class FlutterWorkoutNotificationOutput implements WorkoutNotificationOutput {
  FlutterWorkoutNotificationOutput({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'workout_cues';
  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    AppTime.initialize();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
    );
    _initialized = true;
  }

  @override
  Future<WorkoutNotificationPermissions> requestPermissions({
    bool requestExactAlarms = false,
  }) async {
    await initialize();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      final notifications =
          await android.requestNotificationsPermission() ?? true;
      if (requestExactAlarms) {
        await android.requestExactAlarmsPermission();
      }
      final exact = await android.canScheduleExactNotifications() ?? false;
      return WorkoutNotificationPermissions(
        notifications: notifications,
        exactAlarms: exact,
      );
    }

    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      final granted =
          await ios.requestPermissions(alert: true, sound: true) ?? false;
      return WorkoutNotificationPermissions(
        notifications: granted,
        // iOS non espone un permesso separato per la precisione.
        exactAlarms: granted,
      );
    }
    return const WorkoutNotificationPermissions(
      notifications: true,
      exactAlarms: true,
    );
  }

  @override
  Future<void> schedule(WorkoutCueNotificationRequest request) async {
    await initialize();
    var mode = AndroidScheduleMode.inexactAllowWhileIdle;
    if (request.preferExact) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (await android?.canScheduleExactNotifications() ?? false) {
        mode = AndroidScheduleMode.exactAllowWhileIdle;
      }
    }

    await _plugin.zonedSchedule(
      id: request.id,
      title: request.title,
      body: request.body,
      scheduledDate: AppTime.inRome(request.scheduledAt),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          'Guida allenamento',
          channelDescription:
              'Fine recupero e cambi di fase durante una sessione.',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.alarm,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(presentSound: true),
      ),
      androidScheduleMode: mode,
      payload: request.payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    await initialize();
    await _plugin.cancel(id: id);
  }
}

class WakelockPlusWorkoutOutput implements WorkoutWakeLockOutput {
  const WakelockPlusWorkoutOutput();

  @override
  Future<void> setEnabled(bool enabled) => WakelockPlus.toggle(enable: enabled);
}
