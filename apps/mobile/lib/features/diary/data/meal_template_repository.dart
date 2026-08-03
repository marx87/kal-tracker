import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/meal_template.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:uuid/uuid.dart';

class MealTemplateRepository {
  MealTemplateRepository(
    AppDatabase database, {
    Uuid? uuid,
    DiaryRepository? diaryRepository,
  }) : _database = database,
       _uuid = uuid ?? const Uuid(),
       _diary = diaryRepository ?? DiaryRepository(database, uuid: uuid);

  final AppDatabase _database;
  final Uuid _uuid;
  final DiaryRepository _diary;

  Stream<List<MealTemplate>> watchTemplates(String profileId) {
    final query = _database.select(_database.mealTemplates).join([
      leftOuterJoin(
        _database.mealTemplateItems,
        _database.mealTemplateItems.templateId.equalsExp(
          _database.mealTemplates.id,
        ),
      ),
    ]);

    query
      ..where(
        _database.mealTemplates.profileId.equals(profileId) &
            _database.mealTemplates.deletedAt.isNull(),
      )
      ..orderBy([
        OrderingTerm.desc(_database.mealTemplates.updatedAt),
        OrderingTerm.asc(_database.mealTemplateItems.position),
      ]);

    return query.watch().map((rows) {
      final templates = <String, LocalMealTemplate>{};
      final items = <String, List<MealTemplateItem>>{};
      final order = <String>[];

      for (final row in rows) {
        final template = row.readTable(_database.mealTemplates);
        if (!templates.containsKey(template.id)) {
          templates[template.id] = template;
          items[template.id] = <MealTemplateItem>[];
          order.add(template.id);
        }
        final item = row.readTableOrNull(_database.mealTemplateItems);
        if (item != null) {
          items[template.id]!.add(_toItem(item));
        }
      }

      return order
          .map(
            (id) => MealTemplate.fromItems(
              id: id,
              name: templates[id]!.name,
              mealType: MealType.fromStorage(templates[id]!.mealType),
              items: items[id]!,
              updatedAt: templates[id]!.updatedAt,
            ),
          )
          .toList(growable: false);
    });
  }

  Future<MealTemplate?> getTemplate(String templateId) async {
    final template = await (_database.select(
      _database.mealTemplates,
    )..where((row) => row.id.equals(templateId))).getSingleOrNull();
    if (template == null || template.deletedAt != null) {
      return null;
    }
    final rows =
        await (_database.select(_database.mealTemplateItems)
              ..where((row) => row.templateId.equals(templateId))
              ..orderBy([(row) => OrderingTerm.asc(row.position)]))
            .get();

    return MealTemplate.fromItems(
      id: template.id,
      name: template.name,
      mealType: MealType.fromStorage(template.mealType),
      items: rows.map(_toItem).toList(growable: false),
      updatedAt: template.updatedAt,
    );
  }

  Future<String> saveTemplateFromMeal({
    required String profileId,
    required DateTime day,
    required MealType mealType,
    required String name,
  }) async {
    final templateName = MealTemplate.normalizeName(name);
    final entries = await _diary.entriesForMeal(
      profileId: profileId,
      day: day,
      mealType: mealType,
    );
    if (entries.isEmpty) {
      throw StateError('Questo pasto non ha ancora alimenti da salvare.');
    }
    final items = [
      for (final entry in entries)
        MealTemplateItem(
          foodName: entry.foodName,
          grams: entry.grams,
          per100g: entry.per100g,
        ),
    ];
    for (final item in items) {
      item.validate();
    }
    final now = AppTime.nowUtc();
    final templateId = _uuid.v4();

    await _database.transaction(() async {
      await _database
          .into(_database.mealTemplates)
          .insert(
            MealTemplatesCompanion.insert(
              id: templateId,
              profileId: profileId,
              name: templateName,
              mealType: mealType.storageValue,
              createdAt: now,
              updatedAt: now,
            ),
          );
      for (var index = 0; index < items.length; index++) {
        await _insertItem(
          templateId: templateId,
          position: index,
          item: items[index],
        );
      }
      await _writeUpsertOutbox(
        templateId: templateId,
        profileId: profileId,
        name: templateName,
        mealType: mealType,
        items: items,
        now: now,
      );
    });

    return templateId;
  }

  Future<List<String>> applyTemplate({
    required String templateId,
    required String profileId,
    required DateTime day,
    MealType? mealType,
  }) async {
    final template = await getTemplate(templateId);
    if (template == null) {
      throw StateError('Modello di pasto non trovato.');
    }
    if (template.items.isEmpty) {
      return const [];
    }
    final targetMealType = mealType ?? template.mealType;
    final eatenAt = DiaryDay.instantFor(day);

    return _diary.addEntries(
      profileId: profileId,
      inputs: [
        for (final item in template.items)
          ManualFoodInput(
            foodName: item.foodName,
            grams: item.grams,
            per100g: item.per100g,
            mealType: targetMealType,
            eatenAt: eatenAt,
          ),
      ],
    );
  }

  Future<void> renameTemplate({
    required String templateId,
    required String name,
  }) async {
    final templateName = MealTemplate.normalizeName(name);
    final now = AppTime.nowUtc();

    await _database.transaction(() async {
      final template = await (_database.select(
        _database.mealTemplates,
      )..where((row) => row.id.equals(templateId))).getSingleOrNull();
      if (template == null || template.deletedAt != null) {
        throw StateError('Modello di pasto non trovato.');
      }
      await (_database.update(
        _database.mealTemplates,
      )..where((row) => row.id.equals(templateId))).write(
        MealTemplatesCompanion(
          name: Value(templateName),
          updatedAt: Value(now),
        ),
      );
      final rows =
          await (_database.select(_database.mealTemplateItems)
                ..where((row) => row.templateId.equals(templateId))
                ..orderBy([(row) => OrderingTerm.asc(row.position)]))
              .get();
      await _writeUpsertOutbox(
        templateId: templateId,
        profileId: template.profileId,
        name: templateName,
        mealType: MealType.fromStorage(template.mealType),
        items: rows.map(_toItem).toList(growable: false),
        now: now,
      );
    });
  }

  Future<void> deleteTemplate(String templateId) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final template = await (_database.select(
        _database.mealTemplates,
      )..where((row) => row.id.equals(templateId))).getSingleOrNull();
      if (template == null) {
        throw StateError('Modello di pasto non trovato.');
      }
      if (template.deletedAt != null) {
        return;
      }
      final changedRows =
          await (_database.update(_database.mealTemplates)..where(
                (row) => row.id.equals(templateId) & row.deletedAt.isNull(),
              ))
              .write(
                MealTemplatesCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
      if (changedRows != 1) {
        throw StateError('Il modello di pasto è stato modificato.');
      }
      await _database
          .into(_database.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              id: _uuid.v4(),
              entityType: 'meal_template',
              entityId: templateId,
              operation: 'delete',
              payloadJson: jsonEncode({
                'id': templateId,
                'deleted_at': now.toUtc().toIso8601String(),
              }),
              createdAt: now,
            ),
          );
    });
  }

  Future<void> _insertItem({
    required String templateId,
    required int position,
    required MealTemplateItem item,
  }) async {
    await _database
        .into(_database.mealTemplateItems)
        .insert(
          MealTemplateItemsCompanion.insert(
            id: _uuid.v4(),
            templateId: templateId,
            position: position,
            foodName: item.foodName.trim(),
            grams: item.grams,
            caloriesPer100g: item.per100g.calories,
            proteinPer100g: item.per100g.protein,
            carbsPer100g: item.per100g.carbs,
            fatPer100g: item.per100g.fat,
          ),
        );
  }

  Future<void> _writeUpsertOutbox({
    required String templateId,
    required String profileId,
    required String name,
    required MealType mealType,
    required List<MealTemplateItem> items,
    required DateTime now,
  }) async {
    await _database
        .into(_database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: _uuid.v4(),
            entityType: 'meal_template',
            entityId: templateId,
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': templateId,
              'profile_id': profileId,
              'name': name,
              'meal_type': mealType.storageValue,
              'updated_at': now.toUtc().toIso8601String(),
              'items': [
                for (var index = 0; index < items.length; index++)
                  {
                    'position': index,
                    'food_name': items[index].foodName.trim(),
                    'grams': items[index].grams,
                    'calories_per_100g': items[index].per100g.calories,
                    'protein_per_100g': items[index].per100g.protein,
                    'carbs_per_100g': items[index].per100g.carbs,
                    'fat_per_100g': items[index].per100g.fat,
                  },
              ],
            }),
            createdAt: now,
          ),
        );
  }

  MealTemplateItem _toItem(LocalMealTemplateItem row) => MealTemplateItem(
    foodName: row.foodName,
    grams: row.grams,
    per100g: Nutrients(
      calories: row.caloriesPer100g,
      protein: row.proteinPer100g,
      carbs: row.carbsPer100g,
      fat: row.fatPer100g,
    ),
  );
}
