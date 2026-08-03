import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/photo_meal/presentation/meal_analysis_result.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';

Map<String, Object?> _validFood() => {
  'name': 'Riso basmati',
  'alternatives': ['Riso venere'],
  'minimumGrams': 100,
  'suggestedGrams': 150,
  'maximumGrams': 250,
  'confidence': 0.8,
  'preparation': 'boiled',
  'hiddenIngredients': ['olio'],
  'uncertainty': 'Porzione stimata.',
};

Map<String, Object?> _validPayload() => {
  'foods': [_validFood()],
  'questions': ['Riso in bianco o condito?'],
  'overallConfidence': 0.7,
  'notes': 'Piatto unico.',
};

void _expectRejected(Object? payload) {
  expect(() => MealAnalysisResult.fromJson(payload), throwsFormatException);
}

void main() {
  group('MealAnalysisResult.fromJson', () {
    test('accetta un payload conforme al contratto', () {
      final result = MealAnalysisResult.fromJson(_validPayload());

      expect(result.foods, hasLength(1));
      expect(result.overallConfidence, 0.7);
      expect(result.notes, 'Piatto unico.');
      expect(result.questions, ['Riso in bianco o condito?']);

      final food = result.foods.single;
      expect(food.name, 'Riso basmati');
      expect(food.alternatives, ['Riso venere']);
      expect(food.minimumGrams, 100);
      expect(food.suggestedGrams, 150);
      expect(food.maximumGrams, 250);
      expect(food.confidence, 0.8);
      expect(food.preparation, 'boiled');
      expect(food.preparationLabel, 'Bollito');
      expect(food.hiddenIngredients, ['olio']);
      expect(food.uncertainty, 'Porzione stimata.');
    });

    test('rifiuta ciò che non è un oggetto', () {
      _expectRejected(null);
      _expectRejected('testo');
      _expectRejected([_validPayload()]);
    });

    test('rifiuta chiavi extra o mancanti al livello superiore', () {
      _expectRejected(_validPayload()..['calorie'] = 200);
      _expectRejected(_validPayload()..remove('notes'));
    });

    test('rifiuta foods vuoto o oltre 12 voci', () {
      _expectRejected(_validPayload()..['foods'] = <Object?>[]);
      _expectRejected(
        _validPayload()..['foods'] = List.filled(13, _validFood()),
      );
    });

    test('rifiuta un alimento con chiavi extra o mancanti', () {
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..['calories'] = 100],
      );
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..remove('uncertainty')],
      );
    });

    test('rifiuta fasce grammi incoerenti o fuori scala', () {
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..['minimumGrams'] = 200],
      );
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..['minimumGrams'] = 0],
      );
      _expectRejected(
        _validPayload()
          ..['foods'] = [
            _validFood()
              ..['maximumGrams'] = 3001
              ..['suggestedGrams'] = 3001,
          ],
      );
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..['minimumGrams'] = true],
      );
    });

    test('rifiuta confidence e preparation fuori contratto', () {
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..['confidence'] = 1.2],
      );
      _expectRejected(
        _validPayload()
          ..['foods'] = [_validFood()..['preparation'] = 'steamed'],
      );
      _expectRejected(_validPayload()..['overallConfidence'] = -0.1);
    });

    test('rifiuta liste e testi oltre i limiti', () {
      _expectRejected(
        _validPayload()
          ..['foods'] = [
            _validFood()..['alternatives'] = ['a', 'b', 'c', 'd'],
          ],
      );
      _expectRejected(
        _validPayload()..['questions'] = List.filled(6, 'Domanda?'),
      );
      _expectRejected(_validPayload()..['notes'] = 'x' * 501);
      _expectRejected(
        _validPayload()
          ..['foods'] = [_validFood()..['uncertainty'] = 'x' * 301],
      );
      _expectRejected(
        _validPayload()..['foods'] = [_validFood()..['name'] = '  '],
      );
    });
  });

  group('PhotoMealJob.fromRow', () {
    test('un risultato valido rende il job pronto per la revisione', () {
      final job = PhotoMealJob.fromRow({
        'id': 'job-1',
        'status': 'needs_review',
        'storage_object': 'owner/job-1/meal.jpg',
        'analysis_result': _validPayload(),
        'attempt_count': 1,
        'requested_meal_type': 'lunch',
      });

      expect(job.isReadyForReview, isTrue);
      expect(job.result, isNotNull);
      expect(job.resultError, isNull);
      expect(job.attemptCount, 1);
    });

    test('un risultato corrotto non manda in crash: solo resultError', () {
      final job = PhotoMealJob.fromRow({
        'id': 'job-1',
        'status': 'needs_review',
        'storage_object': 'owner/job-1/meal.jpg',
        'analysis_result': {'foods': <Object?>[]},
      });

      expect(job.isReadyForReview, isFalse);
      expect(job.result, isNull);
      expect(job.resultError, isNotNull);
    });

    test('uno stato sconosciuto non è mai attivo né pronto', () {
      final job = PhotoMealJob.fromRow({
        'id': 'job-1',
        'status': 'qualcosa_di_nuovo',
        'storage_object': 'owner/job-1/meal.jpg',
      });

      expect(job.status, PhotoMealJobStatus.unknown);
      expect(job.isActive, isFalse);
      expect(job.isReadyForReview, isFalse);
    });
  });
}
