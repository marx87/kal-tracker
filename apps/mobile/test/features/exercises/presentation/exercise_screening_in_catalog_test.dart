import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Le righe generate da drift si chiamano come le entità di dominio: qui
// interessano le seconde.
import 'package:kal_tracker/core/database/app_database.dart'
    hide TrainingLimitation, TrainingProfile;
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/exercises/data/exercise_repository.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_detail_screen.dart';
import 'package:kal_tracker/features/exercises/presentation/exercises_screen.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/data/training_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_profile_providers.dart';

/// **Il profilo di allenamento letto dal catalogo.**
///
/// Fino a ieri attrezzatura e limitazioni si scrivevano in Impostazioni e
/// nessuno le rileggeva. Questi test guardano il giro completo — riga sul
/// database, screening, schermata — perché è quello il pezzo che mancava: il
/// dominio da solo era già verde, e non serviva a niente.
///
/// Il caso di riferimento è quello vero del 7 agosto 2026: una spalla che non
/// regge le spinte alte, e una scheda costruita a mano depennando esercizio
/// per esercizio.
void main() {
  late AppDatabase database;
  late ExerciseRepository exercises;
  late TrainingProfileRepository training;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    exercises = ExerciseRepository(database);
    training = TrainingProfileRepository(database);
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  /// Una finestra alta.
  ///
  /// La lista costruisce solo quello che entra nello schermo più un margine:
  /// con la finestra da 600 punti «l'esercizio escluso non c'è» vorrebbe dire
  /// «è due schermate più giù», che è un'altra cosa da quella che questi test
  /// vogliono provare.
  void tallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget home, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database), ...overrides],
        child: MaterialApp(theme: AppTheme.light, home: home),
      );

  Future<Exercise> seed(String name, MuscleGroup group) =>
      exercises.createExercise(
        profileId: profileId,
        draft: ExerciseDraft(name: name, muscleGroup: group),
      );

  /// La casa di Marco: manubri, panca e tappetino. Nessuna sbarra a cui
  /// appendersi, che è quello che rende «Trazioni» un caso vero.
  Future<void> declareEquipment() => training.saveProfile(
    TrainingProfile(
      profileId: profileId,
      equipment: const {
        Equipment.manubri,
        Equipment.pancaRegolabile,
        Equipment.tappetino,
      },
    ),
  );

  Future<void> limitShoulder(LimitationSeverity severity, {String? note}) =>
      training.addLimitation(
        profileId: profileId,
        bodyPart: BodyPart.spallaDx,
        severity: severity,
        note: note,
      );

  testWidgets('senza profilo il catalogo non promette nessun controllo', (
    tester,
  ) async {
    final squat = await seed('Squat a corpo libero', MuscleGroup.gambe);

    tallWindow(tester);
    await tester.pumpWidget(app(const ExercisesScreen()));
    await tester.pumpAndSettle();

    // Niente pastiglie verdi su tutto il catalogo: «libero» detto senza aver
    // guardato niente è una promessa che nessuno ha mantenuto.
    expect(find.byKey(Key('exercise_outcome_${squat.id}')), findsNothing);
    expect(find.text('Libero'), findsNothing);
    // E niente interruttore che promette di nascondere gli esclusi quando non
    // c'è nessun escluso.
    expect(find.byKey(const Key('exercise_practicable_filter')), findsNothing);
    expect(
      find.textContaining('Il profilo di allenamento è vuoto'),
      findsOneWidget,
    );

    await disposeApp(tester);
  });

  testWidgets(
    'spalla in stop: la shoulder press resta, spenta, con il perché',
    (tester) async {
      final press = await seed(
        'Shoulder press con manubri',
        MuscleGroup.spalle,
      );
      final squat = await seed('Squat a corpo libero', MuscleGroup.gambe);
      await declareEquipment();
      await limitShoulder(LimitationSeverity.stop);

      tallWindow(tester);
      await tester.pumpWidget(app(const ExercisesScreen()));
      await tester.pumpAndSettle();

      // Il punto dell'intero lavoro: l'esercizio escluso NON sparisce. Un
      // catalogo che si accorcia in silenzio sembra rotto.
      expect(find.byKey(Key('exercise_card_${press.id}')), findsOneWidget);
      expect(find.text('Shoulder press con manubri'), findsOneWidget);
      expect(find.byKey(Key('exercise_outcome_${press.id}')), findsOneWidget);
      expect(find.text('Escluso'), findsOneWidget);
      expect(
        find.textContaining('spalla destra è in stop'),
        findsOneWidget,
        reason: 'la ragione si legge, non si intuisce dal colore',
      );

      // Lo squat non lo tocca nessuno, e lo dice.
      expect(find.byKey(Key('exercise_outcome_${squat.id}')), findsOneWidget);
      expect(find.text('Libero'), findsOneWidget);

      // In cima la libreria riassume cosa sta facendo il profilo, con una
      // frase e non con due numeri appaiati.
      expect(find.text('Il tuo profilo esclude 1 esercizio.'), findsOneWidget);

      await disposeApp(tester);
    },
  );

  testWidgets('senza attrezzatura dichiarata il conto lo dice', (tester) async {
    // Con una limitazione aperta ma nessun attrezzo dichiarato lo screening
    // salta del tutto il controllo sull'attrezzatura. Un «Libero» che non
    // dichiara di aver guardato solo metà delle cose è un via libera che
    // nessuno ha dato.
    final trazioni = await seed('Trazioni alla sbarra', MuscleGroup.schiena);
    await limitShoulder(LimitationSeverity.fastidio);

    tallWindow(tester);
    await tester.pumpWidget(app(const ExercisesScreen()));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('L\'attrezzatura non entra nel conto'),
      findsOneWidget,
    );
    // La sbarra manca davvero, ma non è per quello che l'esercizio è fuori:
    // qui lo tocca la spalla, e la ragione nomina solo quella.
    expect(find.text('Segnalato'), findsOneWidget);
    expect(find.byKey(Key('exercise_outcome_${trazioni.id}')), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('un fastidio segnala e dice cosa fare al posto suo', (
    tester,
  ) async {
    await seed('Shoulder press con manubri', MuscleGroup.spalle);
    await declareEquipment();
    await limitShoulder(LimitationSeverity.fastidio);

    tallWindow(tester);
    await tester.pumpWidget(app(const ExercisesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Segnalato'), findsOneWidget);
    expect(
      find.textContaining('Da tenere d\'occhio: spalla destra dà fastidio'),
      findsOneWidget,
    );
    // Segnalare senza l'alternativa rimanderebbe a Marco lo stesso lavoro che
    // il profilo esiste per togliergli.
    expect(find.textContaining('Al posto suo:'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('l\'attrezzo che manca si legge per nome', (tester) async {
    await seed('Trazioni alla sbarra', MuscleGroup.schiena);
    await declareEquipment();

    tallWindow(tester);
    await tester.pumpWidget(app(const ExercisesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Escluso'), findsOneWidget);
    expect(
      find.textContaining('serve una sbarra per trazioni'),
      findsOneWidget,
    );

    await disposeApp(tester);
  });

  testWidgets('«solo praticabili» nasconde gli esclusi e dichiara quanti', (
    tester,
  ) async {
    final press = await seed('Shoulder press con manubri', MuscleGroup.spalle);
    await seed('Squat a corpo libero', MuscleGroup.gambe);
    await declareEquipment();
    await limitShoulder(LimitationSeverity.stop);

    tallWindow(tester);
    await tester.pumpWidget(app(const ExercisesScreen()));
    await tester.pumpAndSettle();

    // Il filtro parte spento: la libreria che si apre è quella intera.
    expect(find.byKey(const Key('exercises_hidden_notice')), findsNothing);
    expect(find.byKey(Key('exercise_card_${press.id}')), findsOneWidget);

    await tester.tap(find.byKey(const Key('exercise_practicable_filter')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('exercise_card_${press.id}')), findsNothing);
    expect(find.byKey(const Key('exercises_hidden_notice')), findsOneWidget);
    expect(
      find.text('Sto nascondendo 1 esercizio escluso dal tuo profilo.'),
      findsOneWidget,
      reason: 'una lista più corta senza un numero accanto sembra rotta',
    );

    await tester.tap(find.byKey(const Key('exercises_show_hidden')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('exercise_card_${press.id}')), findsOneWidget);
    expect(find.byKey(const Key('exercises_hidden_notice')), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('le limitazioni illeggibili si dichiarano, non si nascondono', (
    tester,
  ) async {
    await seed('Squat a corpo libero', MuscleGroup.gambe);

    // Il CHECK del database impedisce di scrivere una zona sconosciuta: una
    // riga così arriva dalla sincronizzazione, quindi il profilo si costruisce
    // a mano — è l'unico modo di provare che il catalogo lo dice.
    final profile = TrainingProfile(
      profileId: profileId,
      equipment: const {Equipment.manubri},
      limitations: [
        TrainingLimitation(
          id: 'spalla',
          bodyPart: BodyPart.spallaDx,
          severity: LimitationSeverity.fastidio,
          startedAt: DateTime.utc(2026, 8, 1),
        ),
      ],
      unreadableLimitations: 2,
    );

    await tester.pumpWidget(
      app(
        const ExercisesScreen(),
        overrides: [
          trainingProfileProvider.overrideWith((ref) => Stream.value(profile)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        '2 limitazioni che questa versione dell\'app non sa '
        'leggere',
      ),
      findsOneWidget,
      reason:
          'il setaccio sta lavorando con meno informazioni di quante ce ne '
          'sono, e va detto',
    );

    await disposeApp(tester);
  });

  testWidgets('la scheda di dettaglio nomina la limitazione e la sua nota', (
    tester,
  ) async {
    final press = await seed('Shoulder press con manubri', MuscleGroup.spalle);
    await declareEquipment();
    await limitShoulder(
      LimitationSeverity.stop,
      note: 'Rotazione esterna sopra i 90°',
    );

    tallWindow(tester);
    await tester.pumpWidget(app(ExerciseDetailScreen(exerciseId: press.id)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('exercise_screening_section')), findsOneWidget);
    expect(find.text('Con il tuo profilo'), findsOneWidget);
    expect(find.text('Escluso'), findsOneWidget);
    expect(find.text('La limitazione che lo tocca'), findsOneWidget);
    expect(find.text('Spalla destra · stop'), findsOneWidget);
    expect(find.text('Rotazione esterna sopra i 90°'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('la scheda di dettaglio dice quale attrezzo manca', (
    tester,
  ) async {
    final trazioni = await seed('Trazioni alla sbarra', MuscleGroup.schiena);
    await declareEquipment();

    tallWindow(tester);
    await tester.pumpWidget(app(ExerciseDetailScreen(exerciseId: trazioni.id)));
    await tester.pumpAndSettle();

    expect(find.text('Cosa manca'), findsOneWidget);
    expect(find.text('una sbarra per trazioni'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('senza profilo la scheda lo dice invece di tacere', (
    tester,
  ) async {
    final squat = await seed('Squat a corpo libero', MuscleGroup.gambe);

    tallWindow(tester);
    await tester.pumpWidget(app(ExerciseDetailScreen(exerciseId: squat.id)));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('nessuno ha controllato'),
      findsOneWidget,
      reason:
          'tacere farebbe passare per controllato quel che nessuno ha '
          'guardato',
    );

    await disposeApp(tester);
  });
}
