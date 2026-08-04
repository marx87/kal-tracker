import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/weekly_plan/data/plan_nutrition.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_gateway.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';
import 'package:uuid/uuid.dart';

/// Orchestrazione del piano settimanale: richiesta → coda sul Mac → attesa →
/// slot locali → "Fatto" nel diario.
///
/// Regole incise nel flusso:
/// * il piano lo genera l'AI sul Mac. NESSUN generatore locale di riserva: col
///   Mac spento il piano resta in attesa e poi fallisce con un messaggio
///   onesto, mentre i piani già generati restano leggibili offline;
/// * l'AI sceglie fra le ricette REALI di Marco: il risultato viene validato
///   contro la richiesta salvata ([WeeklyPlanResult.fromJson]) e un id fuori
///   catalogo fa fallire il piano SENZA scrivere un solo slot;
/// * il piano è una previsione: qui non entra nulla nel diario finché Marco
///   non tocca "Fatto" su uno slot.
class WeeklyPlanRepository {
  WeeklyPlanRepository(
    this._database, {
    required this._gateway,
    RecipeRepository? recipeRepository,
    DiaryRepository? diaryRepository,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _uuid = uuid ?? const Uuid(),
       _now = now ?? AppTime.nowUtc {
    _recipes = recipeRepository ?? RecipeRepository(_database);
    _diary = diaryRepository ?? DiaryRepository(_database);
  }

  /// Il Mac non ha ancora preso in carico il job: dopo questo tempo si smette
  /// di aspettare. Lo stato remoto resta 'queued' per sempre (nessun TTL sul
  /// server), quindi il criterio è per forza temporale e sta qui.
  static const Duration queuedTimeout = Duration(minutes: 8);

  /// Job preso in carico ma mai concluso (worker morto a metà).
  static const Duration workTimeout = Duration(minutes: 25);

  static const int _maxNotesLength = WeeklyPlanResult.maxNotesLength;
  static const int _maxFoodNameLength = 160;

  final AppDatabase _database;
  final WeeklyPlanGateway _gateway;
  final Uuid _uuid;
  final DateTime Function() _now;
  late final RecipeRepository _recipes;
  late final DiaryRepository _diary;

  /// Tutti i piani del profilo, dal più recente. Legge SOLO dal database
  /// locale: offline si continua a consultare il piano già generato.
  ///
  /// Lo stream si aggiorna anche quando cambiano gli slot (un "Fatto") o le
  /// ricette (una cancellazione), perché la query le tocca tutte e tre.
  Stream<List<WeeklyPlan>> watchPlans(String profileId) {
    final plans = _database.weeklyPlans;
    final query = _database.select(plans).join([
      leftOuterJoin(
        _database.weeklyPlanSlots,
        _database.weeklyPlanSlots.planId.equalsExp(plans.id),
      ),
      leftOuterJoin(
        _database.fitRecipes,
        _database.fitRecipes.id.equalsExp(_database.weeklyPlanSlots.recipeId) &
            _database.fitRecipes.deletedAt.isNull(),
      ),
    ]);
    query
      ..where(plans.profileId.equals(profileId) & plans.deletedAt.isNull())
      ..orderBy([OrderingTerm.desc(plans.createdAt)]);
    return query.watch().map(_plansFromRows);
  }

  Future<WeeklyPlan?> getPlan(String planId) async {
    final row = await _planRow(planId);
    if (row == null) {
      return null;
    }
    return _planFrom(row, await _slotsOf(planId));
  }

  /// Costruisce la richiesta e accoda il job sul Mac.
  ///
  /// Ordine: prima la sessione, poi il catalogo, poi la riga remota, e solo a
  /// enqueue riuscito la riga locale. Se qualcosa va storto non resta un piano
  /// fantasma in "generazione".
  Future<WeeklyPlan> generatePlan({
    required String profileId,
    required DateTime startDate,
    required int days,
    required Iterable<PlanMeal> meals,
    required NutritionTarget targets,
    String notes = '',
  }) async {
    final account = await _gateway.currentAccount();
    if (account == null) {
      throw const WeeklyPlanException(
        'Per generare il piano serve l’accesso al cloud: vai in Progressi → '
        'Sincronizzazione e accedi.',
        authRequired: true,
      );
    }
    if (await _pendingPlanRow(profileId) != null) {
      throw const WeeklyPlanException(
        'C’è già un piano in preparazione: aspetta che il Mac risponda.',
      );
    }

    final request = WeeklyPlanRequest(
      startDate: startDate,
      days: days,
      meals: meals,
      targets: targets,
      notes: notes,
      recipes: await _recipeDigest(profileId),
    );
    final Map<String, Object?> payload;
    try {
      payload = request.toJson();
    } on FormatException catch (error) {
      throw WeeklyPlanException(error.message);
    }

    final jobId = _uuid.v4();
    final remoteProfileId = await _gateway.ensureRemoteProfile(profileId);
    // SOLO le 5 colonne concesse dal grant: qualsiasi altra colonna (anche
    // con il valore di default) produce 42501.
    await _gateway.enqueueJob({
      'id': jobId,
      'owner_id': account.userId,
      'profile_id': remoteProfileId,
      'request': payload,
      'last_mutation_id': SyncIds.derived('plan-job', jobId),
    });

    final now = _now();
    final planId = _uuid.v4();
    await _database
        .into(_database.weeklyPlans)
        .insert(
          WeeklyPlansCompanion.insert(
            id: planId,
            profileId: profileId,
            startDate: request.startDate,
            days: request.days,
            mealsCsv: PlanMeals.encode(request.meals),
            status: WeeklyPlanStatus.generating.storageValue,
            remoteJobId: Value(jobId),
            requestJson: jsonEncode(payload),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (await getPlan(planId))!;
  }

  /// Un giro di polling su un piano in attesa.
  ///
  /// Ritorna il piano aggiornato (o quello invariato). Gli errori di rete
  /// risalgono al chiamante: per un po' lo stato locale NON si tocca, perché
  /// «non riesco a chiedere» non è «il Mac è spento». Ma passata la finestra
  /// dell'attesa anche il silenzio va dichiarato: un piano che resta «in
  /// preparazione» per sempre non ha vie d'uscita (nessun piano nuovo, nessun
  /// pulsante) e il polling continuerebbe all'infinito.
  Future<WeeklyPlan?> refreshPlan(String planId) async {
    final row = await _planRow(planId);
    if (row == null) {
      return null;
    }
    if (WeeklyPlanStatus.tryFromStorage(row.status) !=
        WeeklyPlanStatus.generating) {
      return getPlan(planId);
    }
    final jobId = row.remoteJobId;
    if (jobId == null) {
      return _fail(row, _macSilentMessage);
    }

    final Map<String, Object?>? remote;
    try {
      remote = await _gateway.fetchJobRow(jobId);
    } on Object {
      if (_now().difference(row.createdAt) > queuedTimeout) {
        // Non si è riuscito a chiedere per tutta la finestra: il motivo vero
        // è questo, e va detto invece di lasciare l'attesa aperta per sempre.
        return _fail(row, _unreachableMessage);
      }
      rethrow;
    }
    final age = _now().difference(row.createdAt);
    if (remote == null) {
      // Riga non trovata: o non è mai arrivata, o è stata rimossa. Si aspetta
      // comunque la finestra del "queued" prima di dichiarare il fallimento.
      return age > queuedTimeout
          ? _fail(row, _macSilentMessage)
          : getPlan(planId);
    }

    final status = remote['status'];
    switch (status) {
      case 'needs_review' || 'confirmed':
        return _materialize(row, remote['result']);
      case 'failed' || 'cancelled' || 'expired':
        final code = remote['error_code'];
        return _fail(
          row,
          code is String && code.trim().isNotEmpty
              ? 'Il Mac non è riuscito a preparare il piano '
                    '(${code.trim()}): riprova quando vuoi.'
              : 'Il Mac non è riuscito a preparare il piano: riprova '
                    'quando vuoi.',
        );
      case 'queued':
        return age > queuedTimeout
            ? _fail(row, _macSilentMessage)
            : getPlan(planId);
      default:
        // claimed / processing: il Mac ci sta lavorando, gli si dà tempo.
        return age > workTimeout
            ? _fail(
                row,
                'Il Mac ha iniziato ma non ha finito: riprova con un piano '
                'più corto o quando è libero.',
              )
            : getPlan(planId);
    }
  }

  /// Porta lo slot nel diario del giorno e del pasto giusti (una sola volta).
  ///
  /// Riusa il flusso delle porzioni di ricetta: grammi e per-100 g dalla
  /// ricetta reale, mai numeri arrivati dal modello.
  Future<WeeklyPlan?> markSlotDone(String slotId) async {
    final slot = await _slotRow(slotId);
    if (slot == null) {
      throw const WeeklyPlanException('Questo pasto non esiste più nel piano.');
    }
    if (slot.doneAt != null) {
      throw const WeeklyPlanException(
        'Questo pasto è già nel diario: annullalo prima di rifarlo.',
      );
    }
    final plan = await _planRow(slot.planId);
    if (plan == null) {
      throw const WeeklyPlanException('Questo piano non esiste più.');
    }
    final recipeId = slot.recipeId;
    final details = recipeId == null
        ? null
        : await _recipes.getRecipe(recipeId);
    if (details == null) {
      throw const WeeklyPlanException(
        'Questa ricetta non è più nel ricettario: sostituiscila.',
      );
    }

    final PlanServingBasis basis;
    try {
      basis = PlanServingBasis.of(details);
    } on FormatException catch (error) {
      throw WeeklyPlanException(error.message);
    }
    final meal = PlanMeal.fromStorage(slot.meal);
    final ids = await _diary.addEntries(
      profileId: plan.profileId,
      inputs: [
        ManualFoodInput(
          foodName: _entryName(details.summary.name, slot.servings),
          grams: basis.gramsFor(slot.servings),
          per100g: basis.per100g,
          mealType: meal.mealType,
          // Il giorno dello slot, non oggi: il piano si può spuntare in
          // anticipo o in ritardo senza sporcare il diario di un altro giorno.
          // `slot.date` è il valore grezzo di drift (un istante riletto nel
          // fuso del telefono): va riportato al giorno del piano con
          // [PlanDate.normalize], altrimenti "Fatto" scrive nel diario del
          // giorno prima.
          eatenAt: DiaryDay.instantFor(PlanDate.normalize(slot.date)),
        ),
      ],
    );

    await (_database.update(
      _database.weeklyPlanSlots,
    )..where((row) => row.id.equals(slotId) & row.doneAt.isNull())).write(
      WeeklyPlanSlotsCompanion(
        doneAt: Value(_now()),
        diaryEntryIds: Value(PlanEntryIds.encode(ids)),
      ),
    );
    return getPlan(slot.planId);
  }

  /// Annulla un "Fatto": toglie dal diario le voci create e riapre lo slot.
  Future<WeeklyPlan?> undoSlotDone(String slotId) async {
    final slot = await _slotRow(slotId);
    if (slot == null) {
      throw const WeeklyPlanException('Questo pasto non esiste più nel piano.');
    }
    for (final entryId in PlanEntryIds.parse(slot.diaryEntryIds)) {
      try {
        await _diary.deleteEntry(entryId);
      } on Object {
        // La voce può essere già stata cancellata a mano dal diario: lo slot
        // va comunque riaperto.
      }
    }
    await (_database.update(
      _database.weeklyPlanSlots,
    )..where((row) => row.id.equals(slotId))).write(
      const WeeklyPlanSlotsCompanion(
        doneAt: Value(null),
        diaryEntryIds: Value(null),
      ),
    );
    return getPlan(slot.planId);
  }

  /// Sostituzione manuale della ricetta di uno slot.
  ///
  /// La motivazione del modello sparisce: parlava della ricetta precedente.
  Future<WeeklyPlan?> replaceSlotRecipe({
    required String slotId,
    required String recipeId,
  }) async {
    final slot = await _slotRow(slotId);
    if (slot == null) {
      throw const WeeklyPlanException('Questo pasto non esiste più nel piano.');
    }
    if (slot.doneAt != null) {
      throw const WeeklyPlanException(
        'Questo pasto è già nel diario: annullalo prima di sostituirlo.',
      );
    }
    final details = await _recipes.getRecipe(recipeId);
    if (details == null) {
      throw const WeeklyPlanException(
        'Questa ricetta non è più nel ricettario.',
      );
    }
    await (_database.update(
      _database.weeklyPlanSlots,
    )..where((row) => row.id.equals(slotId))).write(
      WeeklyPlanSlotsCompanion(
        recipeId: Value(recipeId),
        recipeNameSnapshot: Value(details.summary.name),
        why: const Value(null),
      ),
    );
    return getPlan(slot.planId);
  }

  /// Il catalogo REALE che viaggia con la richiesta: id, nome, tag, minuti e
  /// i valori PER PORZIONE calcolati dall'app dalle ricette vere.
  ///
  /// Lettura una-tantum (niente stream): serve una fotografia del ricettario
  /// nell'istante della richiesta, ed è la stessa fotografia con cui il
  /// risultato verrà validato.
  Future<List<PlanRecipeOption>> _recipeDigest(String profileId) async {
    // Stesso ordine della schermata Ricette: preferite prima, poi le più
    // fresche. Se il ricettario supera il tetto del contratto si taglia in
    // fondo, dove stanno quelle che Marco usa meno.
    final rows =
        await (_database.select(_database.fitRecipes)
              ..where(
                (row) =>
                    row.profileId.equals(profileId) & row.deletedAt.isNull(),
              )
              ..orderBy([
                (row) => OrderingTerm.desc(row.isFavorite),
                (row) => OrderingTerm.desc(row.updatedAt),
              ])
              ..limit(WeeklyPlanRequest.maxRecipes))
            .get();
    if (rows.isEmpty) {
      throw const WeeklyPlanException(
        'Il ricettario è vuoto: aggiungi almeno una ricetta prima di '
        'chiedere il piano.',
      );
    }
    return [
      for (final row in rows) PlanRecipeOption.fromSummary(_summary(row)),
    ];
  }

  /// Vista di una ricetta con i totali denormalizzati (scritti da
  /// `RecipeNutritionCalculator`) divisi per le porzioni: gli stessi numeri
  /// che Marco vede nella schermata Ricette.
  FitRecipeSummary _summary(LocalFitRecipe row) {
    final total = Nutrients(
      calories: row.totalCalories,
      protein: row.totalProtein,
      carbs: row.totalCarbs,
      fat: row.totalFat,
    );
    final divisor = row.servings.toDouble();
    return FitRecipeSummary(
      id: row.id,
      name: row.name,
      description: row.description,
      tags: RecipeTags.parse(row.tags),
      servings: row.servings,
      prepMinutes: row.prepMinutes,
      isFavorite: row.isFavorite,
      nutrition: RecipeNutrition(
        total: total,
        perServing: Nutrients(
          calories: total.calories / divisor,
          protein: total.protein / divisor,
          carbs: total.carbs / divisor,
          fat: total.fat / divisor,
        ),
      ),
      updatedAt: row.updatedAt,
    );
  }

  /// Valida il risultato contro la richiesta salvata e scrive gli slot.
  /// O si scrivono tutti, o il piano fallisce: mai un piano a metà.
  Future<WeeklyPlan?> _materialize(
    LocalWeeklyPlan row,
    Object? rawResult,
  ) async {
    final WeeklyPlanRequest request;
    try {
      request = WeeklyPlanRequest.fromJson(
        jsonDecode(row.requestJson) as Object?,
      );
    } on Object {
      return _fail(
        row,
        'Non riesco a rileggere la richiesta di questo piano: rigeneralo.',
      );
    }
    final WeeklyPlanResult result;
    try {
      result = WeeklyPlanResult.fromJson(rawResult, request: request);
    } on FormatException catch (error) {
      // Qui finisce anche PLAN_UNKNOWN_RECIPE: l'AI sceglie, non inventa.
      return _fail(
        row,
        'Il piano proposto non era valido: ${error.message}. Riprova.',
      );
    } on Object {
      return _fail(row, 'Il piano proposto non era leggibile: riprova.');
    }

    final now = _now();
    // Le ricette cancellate a mano restano leggibili col nome, ma la colonna
    // ha una FK: senza la riga padre l'insert fallirebbe tutto il piano.
    final alive = await _existingRecipeIds({
      for (final slot in result.slots) slot.recipeId,
    });

    await _database.transaction(() async {
      await (_database.delete(
        _database.weeklyPlanSlots,
      )..where((slot) => slot.planId.equals(row.id))).go();
      for (final slot in result.slots) {
        await _database
            .into(_database.weeklyPlanSlots)
            .insert(
              WeeklyPlanSlotsCompanion.insert(
                id: _uuid.v4(),
                planId: row.id,
                date: slot.date,
                meal: slot.meal.storageValue,
                recipeId: Value(
                  alive.contains(slot.recipeId) ? slot.recipeId : null,
                ),
                recipeNameSnapshot: slot.recipeName,
                servings: slot.servings,
                why: Value(slot.why),
              ),
            );
      }
      await (_database.update(
        _database.weeklyPlans,
      )..where((plan) => plan.id.equals(row.id))).write(
        WeeklyPlansCompanion(
          status: Value(WeeklyPlanStatus.ready.storageValue),
          notes: Value(result.notes.isEmpty ? null : _clip(result.notes)),
          updatedAt: Value(now),
        ),
      );
    });
    return getPlan(row.id);
  }

  /// Piano fallito: lo stato resta leggibile e [notes] porta il motivo in
  /// italiano, così il messaggio sopravvive alla chiusura dell'app.
  Future<WeeklyPlan?> _fail(LocalWeeklyPlan row, String message) async {
    await (_database.update(
      _database.weeklyPlans,
    )..where((plan) => plan.id.equals(row.id))).write(
      WeeklyPlansCompanion(
        status: Value(WeeklyPlanStatus.failed.storageValue),
        notes: Value(_clip(message)),
        updatedAt: Value(_now()),
      ),
    );
    return getPlan(row.id);
  }

  Future<Set<String>> _existingRecipeIds(Set<String> ids) async {
    if (ids.isEmpty) {
      return const <String>{};
    }
    final column = _database.fitRecipes.id;
    final rows =
        await (_database.selectOnly(_database.fitRecipes)
              ..addColumns([column])
              ..where(column.isIn(ids.toList())))
            .get();
    return {
      for (final row in rows)
        if (row.read(column) case final String id) id,
    };
  }

  Future<LocalWeeklyPlan?> _planRow(String planId) =>
      (_database.select(_database.weeklyPlans)
            ..where((plan) => plan.id.equals(planId) & plan.deletedAt.isNull()))
          .getSingleOrNull();

  Future<LocalWeeklyPlan?> _pendingPlanRow(String profileId) =>
      (_database.select(_database.weeklyPlans)
            ..where(
              (plan) =>
                  plan.profileId.equals(profileId) &
                  plan.deletedAt.isNull() &
                  plan.status.equals(WeeklyPlanStatus.generating.storageValue),
            )
            ..limit(1))
          .getSingleOrNull();

  Future<LocalWeeklyPlanSlot?> _slotRow(String slotId) => (_database.select(
    _database.weeklyPlanSlots,
  )..where((slot) => slot.id.equals(slotId))).getSingleOrNull();

  /// Slot di un piano con l'informazione «la ricetta esiste ancora?».
  Future<List<WeeklyPlanSlot>> _slotsOf(String planId) async {
    final slots = _database.weeklyPlanSlots;
    final query = _database.select(slots).join([
      leftOuterJoin(
        _database.fitRecipes,
        _database.fitRecipes.id.equalsExp(slots.recipeId) &
            _database.fitRecipes.deletedAt.isNull(),
      ),
    ])..where(slots.planId.equals(planId));
    final rows = await query.get();
    return [
      for (final row in rows)
        _slotFrom(
          row.readTable(slots),
          row.readTableOrNull(_database.fitRecipes),
        ),
    ];
  }

  List<WeeklyPlan> _plansFromRows(List<TypedResult> rows) {
    final plans = <String, LocalWeeklyPlan>{};
    final order = <String>[];
    final slots = <String, List<WeeklyPlanSlot>>{};
    for (final row in rows) {
      final plan = row.readTable(_database.weeklyPlans);
      if (!plans.containsKey(plan.id)) {
        plans[plan.id] = plan;
        order.add(plan.id);
      }
      final slot = row.readTableOrNull(_database.weeklyPlanSlots);
      if (slot != null) {
        slots
            .putIfAbsent(plan.id, () => [])
            .add(_slotFrom(slot, row.readTableOrNull(_database.fitRecipes)));
      }
    }
    return List.unmodifiable([
      for (final id in order)
        _planFrom(plans[id]!, slots[id] ?? const <WeeklyPlanSlot>[]),
    ]);
  }

  WeeklyPlan _planFrom(LocalWeeklyPlan row, List<WeeklyPlanSlot> slots) =>
      WeeklyPlan(
        id: row.id,
        startDate: row.startDate,
        days: row.days,
        meals: PlanMeals.parse(row.mealsCsv),
        status:
            WeeklyPlanStatus.tryFromStorage(row.status) ??
            WeeklyPlanStatus.failed,
        notes: row.notes,
        remoteJobId: row.remoteJobId,
        slots: slots,
      );

  /// La ricetta cancellata (tombstone o riga sparita) azzera [recipeId] ma
  /// lascia il nome: lo slot si mostra come «non più disponibile», mai come
  /// errore.
  WeeklyPlanSlot _slotFrom(LocalWeeklyPlanSlot row, LocalFitRecipe? recipe) =>
      WeeklyPlanSlot(
        id: row.id,
        date: row.date,
        meal: PlanMeal.fromStorage(row.meal),
        recipeId: recipe?.id,
        recipeName: row.recipeNameSnapshot,
        servings: row.servings,
        why: row.why,
        doneAt: row.doneAt,
        diaryEntryIds: PlanEntryIds.parse(row.diaryEntryIds),
      );

  String _entryName(String recipeName, double servings) {
    final suffix = ' · ${planServingsLabel(servings)}';
    final room = _maxFoodNameLength - suffix.length;
    final name = recipeName.length > room
        ? recipeName.substring(0, room)
        : recipeName;
    return '$name$suffix';
  }

  String _clip(String value) => value.length <= _maxNotesLength
      ? value
      : '${value.substring(0, _maxNotesLength - 1)}…';

  static const String _macSilentMessage =
      'Il Mac non ha risposto: riprova quando è acceso. I piani già '
      'generati restano qui.';

  static const String _unreachableMessage =
      'Non sono riuscito a chiedere al Mac come sta andando: controlla la '
      'connessione (e l’accesso al cloud) e rigenera il piano quando vuoi. '
      'I piani già generati restano qui.';
}

/// «1 porzione», «1,5 porzioni»: usata sia nella UI sia nel nome della voce
/// di diario, così il diario e il piano si leggono allo stesso modo.
String planServingsLabel(double servings) {
  final formatted = servings % 1 == 0
      ? servings.toStringAsFixed(0)
      : servings.toStringAsFixed(1).replaceAll('.', ',');
  return servings == 1 ? '1 porzione' : '$formatted porzioni';
}

final weeklyPlanRepositoryProvider = Provider<WeeklyPlanRepository>(
  (ref) => WeeklyPlanRepository(
    ref.watch(databaseProvider),
    gateway: ref.watch(weeklyPlanGatewayProvider),
    recipeRepository: ref.watch(recipeRepositoryProvider),
    diaryRepository: ref.watch(diaryRepositoryProvider),
  ),
);
