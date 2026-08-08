import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';
import 'package:kal_tracker/features/workouts/cues/presentation/workout_cue_settings_section.dart';

void main() {
  testWidgets('cambia livello voce e preferenze senza linguaggio tecnico', (
    tester,
  ) async {
    var current = const WorkoutCuePreferences();

    Widget app() => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: WorkoutCueSettingsSection(
              preferences: current,
              onChanged: (value) => setState(() => current = value),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('voice_level_detailed')));
    await tester.pump();
    expect(current.voice, VoiceGuidanceLevel.detailed);

    await tester.tap(find.byKey(const Key('workout_awake_toggle')));
    await tester.pump();
    expect(current.keepScreenAwake, isTrue);
    expect(find.textContaining('wake-lock'), findsNothing);
    expect(find.textContaining('TTS'), findsNothing);
  });

  testWidgets('resta usabile a 320 px con testo al 150%', (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: WorkoutCueSettingsSection(
              preferences: WorkoutCuePreferences(),
              onChanged: _ignore,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('workout_cue_settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

void _ignore(WorkoutCuePreferences _) {}
