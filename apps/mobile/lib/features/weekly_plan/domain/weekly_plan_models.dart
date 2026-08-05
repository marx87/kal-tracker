/// Modello condiviso del piano settimanale.
///
/// Regole non negoziabili incise qui, una volta sola per tutti:
/// * l'AI SCEGLIE, non inventa: può indicare solo `recipeId` presenti nel
///   catalogo inviato con la richiesta ([WeeklyPlanRequest.recipes]); un id
///   sconosciuto rende il risultato invalido (nessun piano a metà);
/// * l'AI non dichiara MAI calorie o macro: nel risultato non esiste alcun
///   campo nutrizionale e ogni eventuale campo in più viene IGNORATO, mai
///   letto e mai mostrato. I numeri li calcola sempre l'app dalle ricette
///   reali con `NutritionCalculator`. Nemmeno la prosa fa eccezione: `why` e
///   `notes` finiscono a schermo alla lettera, quindi un testo con cifre
///   («circa 600 kcal») viene scartato ([_freeText]) e lo slot resta con i
///   soli numeri calcolati;
/// * il piano è una PREVISIONE: qui non si scrive nel diario. Uno slot entra
///   nel diario solo quando Marco tocca "Fatto".
///
/// La validazione del risultato è una funzione pura ([WeeklyPlanResult.fromJson])
/// che riceve la richiesta come unico contesto: è testabile senza database,
/// senza rete e senza Flutter, e va rieseguita anche a lettura, perché il
/// piano transita in un jsonb libero.
library;

import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';

/// I pasti pianificabili. Marco li seleziona a caselle prima di ogni
/// generazione, quindi l'insieme richiesto cambia da piano a piano.
///
/// L'ordine di dichiarazione è quello del contratto ed è anche l'ordine di
/// ordinamento degli slot dentro un giorno.
enum PlanMeal {
  colazione('colazione', 'Colazione', MealType.breakfast),
  pranzo('pranzo', 'Pranzo', MealType.lunch),
  cena('cena', 'Cena', MealType.dinner),
  spuntino('spuntino', 'Spuntino', MealType.snack);

  const PlanMeal(this.storageValue, this.label, this.mealType);

  /// Valore usato nel JSON del contratto e nella colonna `meal`.
  final String storageValue;

  /// Etichetta italiana da mostrare.
  final String label;

  /// Pasto corrispondente nel diario, per l'inserimento con "Fatto".
  final MealType mealType;

  static PlanMeal? tryFromStorage(Object? value) {
    if (value is! String) {
      return null;
    }
    final normalized = value.trim().toLowerCase();
    for (final meal in PlanMeal.values) {
      if (meal.storageValue == normalized) {
        return meal;
      }
    }
    return null;
  }

  static PlanMeal fromStorage(Object? value) {
    final meal = tryFromStorage(value);
    if (meal == null) {
      throw FormatException('Pasto non riconosciuto: $value');
    }
    return meal;
  }
}

/// Codifica dei pasti richiesti nella colonna `meals_csv`.
abstract final class PlanMeals {
  /// Elimina i doppioni e riporta i pasti nell'ordine di [PlanMeal.values].
  static List<PlanMeal> normalize(Iterable<PlanMeal> meals) {
    final selected = meals.toSet();
    return List.unmodifiable([
      for (final meal in PlanMeal.values)
        if (selected.contains(meal)) meal,
    ]);
  }

  static String encode(Iterable<PlanMeal> meals) =>
      normalize(meals).map((meal) => meal.storageValue).join(',');

  /// Lettura tollerante dal database: una voce sconosciuta viene saltata,
  /// perché una riga vecchia non deve rendere illeggibile un piano.
  static List<PlanMeal> parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <PlanMeal>[];
    }
    return normalize([
      for (final part in raw.split(','))
        if (PlanMeal.tryFromStorage(part) case final PlanMeal meal) meal,
    ]);
  }
}

/// Stato del piano nella tabella locale `weekly_plans`.
enum WeeklyPlanStatus {
  /// Job accodato: il Mac non ha ancora risposto.
  generating('generating'),

  /// Piano valido e consultabile offline.
  ready('ready'),

  /// Generazione fallita (Mac spento, risultato rifiutato, errore del worker).
  failed('failed');

  const WeeklyPlanStatus(this.storageValue);

  final String storageValue;

  static WeeklyPlanStatus? tryFromStorage(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final status in WeeklyPlanStatus.values) {
      if (status.storageValue == value) {
        return status;
      }
    }
    return null;
  }

  static WeeklyPlanStatus fromStorage(Object? value) {
    final status = tryFromStorage(value);
    if (status == null) {
      throw FormatException('Stato del piano non riconosciuto: $value');
    }
    return status;
  }
}

/// Date di calendario del piano.
///
/// Un giorno del piano è una data, non un istante: si rappresenta come
/// `DateTime.utc(anno, mese, giorno)` così che confronti, chiavi e
/// serializzazione ISO restino stabili senza dipendere dal fuso.
abstract final class PlanDate {
  /// Riporta un istante qualsiasi al giorno del calendario di Marco.
  ///
  /// L'istante va SEMPRE riletto a Roma prima di guardarne i componenti:
  /// drift salva le date come istanti unix e le rilegge nel fuso del
  /// telefono, quindi un `value.day` alla cieca sposterebbe indietro di un
  /// giorno tutto il piano ogni volta che il fuso è dietro a UTC (mercoledì
  /// diventa martedì, e "Fatto" scriverebbe nel diario del giorno sbagliato).
  /// Il resto dell'app fa già così passando da [AppTime].
  static DateTime normalize(DateTime value) {
    final inRome = AppTime.inRome(value);
    return DateTime.utc(inRome.year, inRome.month, inRome.day);
  }

  static DateTime addDays(DateTime date, int days) {
    final start = normalize(date);
    return DateTime.utc(start.year, start.month, start.day + days);
  }

  static String format(DateTime date) {
    final normalized = normalize(date);
    final month = normalized.month.toString().padLeft(2, '0');
    final day = normalized.day.toString().padLeft(2, '0');
    return '${normalized.year.toString().padLeft(4, '0')}-$month-$day';
  }

  static DateTime parse(Object? value) {
    if (value is! String) {
      throw const FormatException('La data deve essere una stringa ISO.');
    }
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Data non valida: $value');
    }
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw FormatException('Data inesistente: $value');
    }
    return date;
  }
}

/// Una ricetta REALE del ricettario, come viene proposta al pianificatore.
///
/// I valori per porzione sono calcolati dall'app (mai dal modello) e servono
/// solo a far scegliere bene: nel risultato non torneranno mai indietro.
class PlanRecipeOption {
  PlanRecipeOption({
    required this.id,
    required this.name,
    required this.servingKcal,
    required this.servingProtein,
    required this.servingCarbs,
    required this.servingFat,
    Iterable<String> tags = const <String>[],
    this.prepMinutes = 0,
  }) : tags = List.unmodifiable(tags);

  /// Vista di una ricetta del ricettario, con i valori per porzione già
  /// calcolati da `RecipeNutritionCalculator` e arrotondati a 1 decimale.
  factory PlanRecipeOption.fromSummary(FitRecipeSummary summary) {
    final perServing = summary.nutrition.perServing;
    return PlanRecipeOption(
      id: summary.id,
      name: summary.name,
      tags: summary.tags,
      prepMinutes: summary.prepMinutes,
      servingKcal: _round1(perServing.calories),
      servingProtein: _round1(perServing.protein),
      servingCarbs: _round1(perServing.carbs),
      servingFat: _round1(perServing.fat),
    );
  }

  factory PlanRecipeOption.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Ogni ricetta deve essere un oggetto.');
    }
    return PlanRecipeOption(
      id: _requiredString(value['id'], 'id', maxLength: 64),
      name: _requiredString(value['name'], 'name', maxLength: 160),
      tags: _stringList(value['tags'], 'tags', 8, maxLength: 24),
      prepMinutes: _wholeNumber(value['prepMinutes'], 'prepMinutes', 10080),
      servingKcal: _nonNegative(value['servingKcal'], 'servingKcal'),
      servingProtein: _nonNegative(value['servingProtein'], 'servingProtein'),
      servingCarbs: _nonNegative(value['servingCarbs'], 'servingCarbs'),
      servingFat: _nonNegative(value['servingFat'], 'servingFat'),
    );
  }

  final String id;
  final String name;
  final List<String> tags;
  final int prepMinutes;
  final double servingKcal;
  final double servingProtein;
  final double servingCarbs;
  final double servingFat;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tags': tags,
    'prepMinutes': prepMinutes,
    'servingKcal': servingKcal,
    'servingProtein': servingProtein,
    'servingCarbs': servingCarbs,
    'servingFat': servingFat,
  };
}

/// Un giorno in cui Marco si allena, come lo vede il pianificatore dei pasti.
///
/// Non è una scelta del modello e non torna mai indietro dal Mac: gli
/// allenamenti li decide la settimana delle schede (`routine_weekly_plan`),
/// qui viaggiano solo per far collocare il pasto proteico DOPO la sessione.
///
/// [proteinMeal] lo calcola l'app, non il modello: è il primo pasto richiesto
/// che cade dopo l'ora in cui Marco si allena davvero (vedi
/// `post_workout_meal.dart`). Resta nullo quando quell'ora non si conosce
/// ancora o quando nessun pasto richiesto viene dopo.
class PlanWorkoutDay {
  PlanWorkoutDay({
    required DateTime date,
    required String name,
    this.proteinMeal,
  }) : date = PlanDate.normalize(date),
       name = _routineName(name);

  factory PlanWorkoutDay.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Ogni allenamento deve essere un oggetto.');
    }
    final rawMeal = value['proteinMeal'];
    return PlanWorkoutDay(
      date: PlanDate.parse(value['date']),
      name: _requiredString(value['name'], 'name', maxLength: maxNameLength),
      proteinMeal: rawMeal == null ? null : PlanMeal.fromStorage(rawMeal),
    );
  }

  static const int maxNameLength = 160;

  /// Il giorno di calendario dell'allenamento (dentro il periodo del piano).
  final DateTime date;

  /// Nome della scheda: al modello serve solo per motivare in italiano.
  final String name;

  /// Il pasto (fra quelli richiesti) che segue l'allenamento.
  final PlanMeal? proteinMeal;

  Map<String, Object?> toJson() => {
    'date': PlanDate.format(date),
    'name': name,
    if (proteinMeal case final meal?) 'proteinMeal': meal.storageValue,
  };

  /// Il nome è uno scatto preso dal database: se è vuoto o lunghissimo non si
  /// rifiuta la richiesta, si aggiusta. Un piano non si perde per un'etichetta.
  static String _routineName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Allenamento';
    }
    return trimmed.length <= maxNameLength
        ? trimmed
        : trimmed.substring(0, maxNameLength);
  }
}

/// La richiesta che il client mette nel job: è anche il CONTRATTO con cui il
/// risultato viene validato (giorni, pasti ammessi, ricette ammesse).
class WeeklyPlanRequest {
  WeeklyPlanRequest({
    required DateTime startDate,
    required this.days,
    required Iterable<PlanMeal> meals,
    required this.targets,
    required Iterable<PlanRecipeOption> recipes,
    Iterable<PlanWorkoutDay> workouts = const <PlanWorkoutDay>[],
    String notes = '',
  }) : startDate = PlanDate.normalize(startDate),
       meals = PlanMeals.normalize(meals),
       recipes = List.unmodifiable(recipes),
       workouts = List.unmodifiable(
         workouts.toList()
           ..sort((first, second) => first.date.compareTo(second.date)),
       ),
       notes = notes.trim();

  /// Rilettura della richiesta salvata in `weekly_plans.request_json`.
  factory WeeklyPlanRequest.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('La richiesta deve essere un oggetto.');
    }
    final schema = value['schema'];
    if (schema != null && schema != schemaVersion) {
      throw FormatException('Schema della richiesta non supportato: $schema');
    }
    final rawMeals = value['meals'];
    if (rawMeals is! List) {
      throw const FormatException('meals deve essere una lista di pasti.');
    }
    final rawRecipes = value['recipes'];
    if (rawRecipes is! List) {
      throw const FormatException('recipes deve essere una lista.');
    }
    final rawTargets = value['targets'];
    if (rawTargets is! Map) {
      throw const FormatException('targets deve essere un oggetto.');
    }
    final rawNotes = value['notes'];
    if (rawNotes != null && rawNotes is! String) {
      throw const FormatException('notes deve essere una stringa.');
    }
    // Chiave aggiunta dopo: una richiesta salvata prima del piano unificato
    // non ha allenamenti, e deve restare rileggibile senza errori.
    final rawWorkouts = value['workouts'];
    if (rawWorkouts != null && rawWorkouts is! List) {
      throw const FormatException('workouts deve essere una lista.');
    }

    final request = WeeklyPlanRequest(
      startDate: PlanDate.parse(value['startDate']),
      days: _wholeNumber(value['days'], 'days', maxDays),
      meals: rawMeals.map(PlanMeal.fromStorage),
      targets: NutritionTarget(
        calories: _nonNegative(rawTargets['calories'], 'calories'),
        protein: _nonNegative(rawTargets['protein'], 'protein'),
        carbs: _nonNegative(rawTargets['carbs'], 'carbs'),
        fat: _nonNegative(rawTargets['fat'], 'fat'),
      ),
      recipes: rawRecipes.map(PlanRecipeOption.fromJson),
      workouts: (rawWorkouts as List? ?? const <Object?>[]).map(
        PlanWorkoutDay.fromJson,
      ),
      notes: rawNotes as String? ?? '',
    );
    request.validate();
    return request;
  }

  static const int schemaVersion = 1;
  static const int maxDays = 14;
  static const int maxNotesLength = 500;
  static const int maxRecipes = 400;

  /// Primo giorno del piano (data di calendario, vedi [PlanDate]).
  final DateTime startDate;
  final int days;
  final List<PlanMeal> meals;
  final NutritionTarget targets;
  final String notes;

  /// Catalogo REALE inviato all'AI: l'unico insieme di scelte ammesse.
  final List<PlanRecipeOption> recipes;

  /// I giorni in cui Marco si allena, in ordine di data. Non sono una scelta
  /// del modello: arrivano dalla settimana delle schede e servono solo a
  /// collocare il pasto proteico dopo la sessione.
  final List<PlanWorkoutDay> workouts;

  /// Le date coperte dal piano, da [startDate] compreso.
  List<DateTime> get dates => List.unmodifiable([
    for (var offset = 0; offset < days; offset++)
      PlanDate.addDays(startDate, offset),
  ]);

  Set<String> get recipeIds => {for (final recipe in recipes) recipe.id};

  Map<String, String> get recipeNamesById => {
    for (final recipe in recipes) recipe.id: recipe.name,
  };

  void validate() {
    if (days < 1 || days > maxDays) {
      throw const FormatException('Il piano copre da 1 a 14 giorni.');
    }
    if (meals.isEmpty) {
      throw const FormatException('Scegli almeno un pasto da pianificare.');
    }
    if (notes.length > maxNotesLength) {
      throw const FormatException(
        'Le note della richiesta sono troppo lunghe.',
      );
    }
    if (recipes.isEmpty) {
      throw const FormatException(
        'Serve almeno una ricetta nel ricettario per generare un piano.',
      );
    }
    if (recipes.length > maxRecipes) {
      throw const FormatException('Troppe ricette nella richiesta.');
    }
    if (recipeIds.length != recipes.length) {
      throw const FormatException('Il catalogo contiene ricette duplicate.');
    }
    final planDates = {for (final date in dates) PlanDate.format(date)};
    final seenWorkouts = <String>{};
    for (final workout in workouts) {
      final key = PlanDate.format(workout.date);
      if (!planDates.contains(key)) {
        throw FormatException(
          'L’allenamento del $key non cade nei giorni del piano.',
        );
      }
      if (!seenWorkouts.add(key)) {
        throw FormatException('Il giorno $key ha due allenamenti.');
      }
      final proteinMeal = workout.proteinMeal;
      if (proteinMeal != null && !meals.contains(proteinMeal)) {
        throw FormatException(
          'Il pasto dopo l’allenamento (${proteinMeal.label.toLowerCase()}) '
          'non è fra quelli da pianificare.',
        );
      }
    }
    targets.validate();
  }

  /// Payload del job. Valida sempre prima di serializzare: una richiesta
  /// incoerente non deve mai arrivare al pianificatore.
  Map<String, Object?> toJson() {
    validate();
    return {
      'schema': schemaVersion,
      'days': days,
      'startDate': PlanDate.format(startDate),
      'meals': [for (final meal in meals) meal.storageValue],
      'targets': {
        'calories': targets.calories,
        'protein': targets.protein,
        'carbs': targets.carbs,
        'fat': targets.fat,
      },
      'notes': notes,
      'recipes': [for (final recipe in recipes) recipe.toJson()],
      'workouts': [for (final workout in workouts) workout.toJson()],
    };
  }
}

/// Uno slot appena uscito dal pianificatore e già validato, ma non ancora
/// salvato: l'id lo assegna il repository quando scrive il piano.
class WeeklyPlanSlotDraft {
  const WeeklyPlanSlotDraft({
    required this.date,
    required this.meal,
    required this.recipeId,
    required this.recipeName,
    required this.servings,
    this.why,
  });

  final DateTime date;
  final PlanMeal meal;
  final String recipeId;

  /// Nome della ricetta al momento della generazione: resta leggibile anche
  /// se la ricetta viene cancellata più tardi.
  final String recipeName;
  final double servings;
  final String? why;

  Map<String, Object?> toJson() => {
    'meal': meal.storageValue,
    'recipeId': recipeId,
    'servings': servings,
    if (why != null) 'why': why,
  };
}

/// Il risultato del pianificatore, validato contro la richiesta.
///
/// Contiene SOLO scelte: ricetta, porzioni e una motivazione in italiano.
/// Nessun numero nutrizionale, per costruzione.
class WeeklyPlanResult {
  WeeklyPlanResult({
    required Iterable<WeeklyPlanSlotDraft> slots,
    this.notes = '',
  }) : slots = List.unmodifiable(slots);

  /// Validazione rigorosa del jsonb prodotto dal worker (funzione pura).
  ///
  /// Rifiuta: ricette fuori catalogo, porzioni fuori fascia o non multiple di
  /// mezza porzione, pasti non richiesti, giorni mancanti/estranei/duplicati,
  /// due slot per lo stesso pasto dello stesso giorno.
  /// Ignora invece qualsiasi chiave in più (comprese eventuali calorie).
  factory WeeklyPlanResult.fromJson(
    Object? value, {
    required WeeklyPlanRequest request,
  }) {
    request.validate();
    if (value is! Map) {
      throw const FormatException('Il piano deve essere un oggetto.');
    }
    final schema = value['schema'];
    if (schema != null && schema != WeeklyPlanRequest.schemaVersion) {
      throw FormatException('Schema del piano non supportato: $schema');
    }
    final rawDays = value['days'];
    if (rawDays is! List) {
      throw const FormatException('days deve essere una lista di giorni.');
    }
    if (rawDays.length != request.days) {
      throw FormatException(
        'Il piano deve avere ${request.days} giorni, non ${rawDays.length}.',
      );
    }

    final allowedMeals = request.meals.toSet();
    final recipeNames = request.recipeNamesById;
    final missingDates = {
      for (final date in request.dates) PlanDate.format(date),
    };
    final slots = <WeeklyPlanSlotDraft>[];

    for (final rawDay in rawDays) {
      if (rawDay is! Map) {
        throw const FormatException('Ogni giorno deve essere un oggetto.');
      }
      final date = PlanDate.parse(rawDay['date']);
      final key = PlanDate.format(date);
      if (!missingDates.remove(key)) {
        throw FormatException('Il giorno $key non fa parte del piano.');
      }
      final rawSlots = rawDay['slots'];
      if (rawSlots is! List) {
        throw FormatException('slots del giorno $key deve essere una lista.');
      }
      if (rawSlots.length > allowedMeals.length) {
        throw FormatException('Troppi pasti nel giorno $key.');
      }

      final usedMeals = <PlanMeal>{};
      for (final rawSlot in rawSlots) {
        if (rawSlot is! Map) {
          throw const FormatException('Ogni pasto deve essere un oggetto.');
        }
        final meal = PlanMeal.tryFromStorage(rawSlot['meal']);
        if (meal == null || !allowedMeals.contains(meal)) {
          throw FormatException(
            'Il pasto "${rawSlot['meal']}" non è tra quelli richiesti.',
          );
        }
        if (!usedMeals.add(meal)) {
          throw FormatException(
            'Il giorno $key ha due volte il pasto ${meal.label.toLowerCase()}.',
          );
        }
        final recipeId = _requiredString(
          rawSlot['recipeId'],
          'recipeId',
          maxLength: 64,
        );
        final recipeName = recipeNames[recipeId];
        if (recipeName == null) {
          // PLAN_UNKNOWN_RECIPE: l'AI sceglie, non inventa.
          throw FormatException(
            'La ricetta $recipeId non è nel ricettario inviato.',
          );
        }
        slots.add(
          WeeklyPlanSlotDraft(
            date: date,
            meal: meal,
            recipeId: recipeId,
            recipeName: recipeName,
            servings: _servings(rawSlot['servings']),
            why: _freeText(rawSlot['why'], 'why', maxLength: maxWhyLength),
          ),
        );
      }
    }

    if (missingDates.isNotEmpty) {
      final missing = missingDates.toList()..sort();
      throw FormatException(
        'Mancano dei giorni nel piano: ${missing.join(', ')}.',
      );
    }

    final planNotes =
        _freeText(value['notes'], 'notes', maxLength: maxNotesLength) ?? '';

    slots.sort(_bySlotOrder);
    return WeeklyPlanResult(slots: slots, notes: planNotes);
  }

  static const double minimumServings = 0.5;
  static const double maximumServings = 4;

  /// Il contratto chiede motivazioni da 140 caratteri: qui si accetta fino al
  /// limite della colonna, per non buttare via un piano buono per un carattere.
  static const int maxWhyLength = 200;
  static const int maxNotesLength = 400;

  /// Slot ordinati per data e, dentro il giorno, per ordine dei pasti.
  final List<WeeklyPlanSlotDraft> slots;

  /// Commento generale del modello (mai numeri nutrizionali).
  final String notes;

  List<WeeklyPlanSlotDraft> slotsFor(DateTime date) {
    final key = PlanDate.format(date);
    return List.unmodifiable([
      for (final slot in slots)
        if (PlanDate.format(slot.date) == key) slot,
    ]);
  }

  /// Forma canonica del risultato: stessa struttura del contratto, senza le
  /// eventuali chiavi in più scartate in lettura.
  Map<String, Object?> toJson() {
    final byDate = <String, List<WeeklyPlanSlotDraft>>{};
    for (final slot in slots) {
      byDate.putIfAbsent(PlanDate.format(slot.date), () => []).add(slot);
    }
    final dates = byDate.keys.toList()..sort();
    return {
      'schema': WeeklyPlanRequest.schemaVersion,
      'days': [
        for (final date in dates)
          {
            'date': date,
            'slots': [for (final slot in byDate[date]!) slot.toJson()],
          },
      ],
      'notes': notes,
    };
  }
}

/// Uno slot salvato: ha un id e sa se è già finito nel diario.
class WeeklyPlanSlot {
  WeeklyPlanSlot({
    required this.id,
    required DateTime date,
    required this.meal,
    required this.recipeName,
    required this.servings,
    this.recipeId,
    this.why,
    this.doneAt,
    Iterable<String> diaryEntryIds = const <String>[],
  }) : date = PlanDate.normalize(date),
       diaryEntryIds = List.unmodifiable(diaryEntryIds);

  final String id;
  final DateTime date;
  final PlanMeal meal;

  /// Null quando la ricetta è stata cancellata dopo la generazione: lo slot
  /// resta leggibile con [recipeName] ma non è più "Fatto"-abile.
  final String? recipeId;
  final String recipeName;
  final double servings;
  final String? why;

  /// Valorizzato quando Marco ha confermato lo slot nel diario.
  final DateTime? doneAt;

  /// Voci del diario create dal "Fatto" (per poterle ritrovare).
  final List<String> diaryEntryIds;

  bool get isDone => doneAt != null;

  /// La ricetta esiste ancora nel ricettario locale.
  bool get hasRecipe => recipeId != null;
}

/// Il piano come lo legge l'app: intestazione + slot.
class WeeklyPlan {
  WeeklyPlan({
    required this.id,
    required DateTime startDate,
    required this.days,
    required Iterable<PlanMeal> meals,
    required this.status,
    Iterable<WeeklyPlanSlot> slots = const <WeeklyPlanSlot>[],
    this.notes,
    this.remoteJobId,
  }) : startDate = PlanDate.normalize(startDate),
       meals = PlanMeals.normalize(meals),
       slots = List.unmodifiable(
         slots.toList()..sort(
           (first, second) => first.date == second.date
               ? first.meal.index.compareTo(second.meal.index)
               : first.date.compareTo(second.date),
         ),
       );

  final String id;
  final DateTime startDate;
  final int days;
  final List<PlanMeal> meals;
  final WeeklyPlanStatus status;
  final String? notes;

  /// Job remoto che ha generato (o sta generando) il piano.
  final String? remoteJobId;
  final List<WeeklyPlanSlot> slots;

  List<DateTime> get dates => List.unmodifiable([
    for (var offset = 0; offset < days; offset++)
      PlanDate.addDays(startDate, offset),
  ]);

  List<WeeklyPlanSlot> slotsFor(DateTime date) {
    final key = PlanDate.format(date);
    return List.unmodifiable([
      for (final slot in slots)
        if (PlanDate.format(slot.date) == key) slot,
    ]);
  }

  bool get isReady => status == WeeklyPlanStatus.ready;

  int get doneCount => slots.where((slot) => slot.isDone).length;
}

/// CSV degli id delle voci di diario create da uno slot "Fatto".
abstract final class PlanEntryIds {
  static String? encode(Iterable<String> ids) {
    final cleaned = [
      for (final id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    return cleaned.isEmpty ? null : cleaned.join(',');
  }

  static List<String> parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String>[];
    }
    return List.unmodifiable([
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ]);
  }
}

int _bySlotOrder(WeeklyPlanSlotDraft first, WeeklyPlanSlotDraft second) =>
    first.date == second.date
    ? first.meal.index.compareTo(second.meal.index)
    : first.date.compareTo(second.date);

double _round1(double value) => (value * 10).roundToDouble() / 10;

/// Porzioni ammesse: da mezza a quattro, a passi di mezza porzione.
double _servings(Object? value) {
  if (value is! num) {
    throw const FormatException('servings deve essere numerico.');
  }
  final servings = value.toDouble();
  if (!servings.isFinite ||
      servings < WeeklyPlanResult.minimumServings ||
      servings > WeeklyPlanResult.maximumServings) {
    throw FormatException(
      'Le porzioni devono stare fra ${WeeklyPlanResult.minimumServings} '
      'e ${WeeklyPlanResult.maximumServings}: $value',
    );
  }
  final halves = servings * 2;
  if ((halves - halves.roundToDouble()).abs() > 1e-9) {
    throw FormatException('Le porzioni vanno a passi di mezza: $value');
  }
  return halves.roundToDouble() / 2;
}

double _nonNegative(Object? value, String field) {
  if (value is! num) {
    throw FormatException('$field deve essere numerico.');
  }
  final result = value.toDouble();
  if (!result.isFinite || result < 0) {
    throw FormatException('$field non può essere negativo.');
  }
  return result;
}

int _wholeNumber(Object? value, String field, int maximum) {
  if (value is! int) {
    throw FormatException('$field deve essere un numero intero.');
  }
  if (value < 0 || value > maximum) {
    throw FormatException('$field deve stare fra 0 e $maximum.');
  }
  return value;
}

String _requiredString(Object? value, String field, {required int maxLength}) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field deve essere una stringa non vuota.');
  }
  final normalized = value.trim();
  if (normalized.length > maxLength) {
    throw FormatException('$field supera $maxLength caratteri.');
  }
  return normalized;
}

String? _optionalString(Object? value, String field, {required int maxLength}) {
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('$field deve essere una stringa.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return null;
  }
  if (normalized.length > maxLength) {
    throw FormatException('$field supera $maxLength caratteri.');
  }
  return normalized;
}

/// Cifre nel testo libero del modello: vietate, vedi [_freeText].
final RegExp _digit = RegExp('[0-9]');

/// Testo libero scritto dal modello (`why`, `notes`): ammesso, ma senza cifre.
///
/// È l'altra metà di «l'AI non dichiara MAI calorie o macro»: la struttura non
/// ha campi nutrizionali, ma questi due campi vanno a schermo alla lettera,
/// accanto ai valori calcolati dall'app. Un «circa 600 kcal» accanto a «772
/// kcal» darebbe a Marco due numeri diversi, e quello sbagliato sarebbe il
/// numero dichiarato dal modello.
///
/// Un piano buono non si butta per una frase: il testo con cifre sparisce
/// (null), come ogni altra chiave in più.
String? _freeText(Object? value, String field, {required int maxLength}) {
  final text = _optionalString(value, field, maxLength: maxLength);
  return text == null || _digit.hasMatch(text) ? null : text;
}

List<String> _stringList(
  Object? value,
  String field,
  int maxItems, {
  required int maxLength,
}) {
  if (value == null) {
    return const <String>[];
  }
  if (value is! List || value.length > maxItems) {
    throw FormatException('$field deve contenere al massimo $maxItems voci.');
  }
  return List.unmodifiable([
    for (final (index, item) in value.indexed)
      _requiredString(item, '$field[$index]', maxLength: maxLength),
  ]);
}
