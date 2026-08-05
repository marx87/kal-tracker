import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/onboarding/domain/personal_details.dart';

void main() {
  group('BiologicalSex', () {
    test('la lettera salvata è quella che accetta il CHECK remoto', () {
      expect(BiologicalSex.male.code, 'M');
      expect(BiologicalSex.female.code, 'F');
    });

    test('una lettera sconosciuta o assente non diventa un valore', () {
      // Un profilo vecchio ha `sex` nullo, e un giorno potrebbe arrivare da
      // un altro dispositivo una lettera che questa versione non conosce:
      // in nessuno dei due casi si deve inventare «Uomo».
      expect(BiologicalSex.fromCode(null), isNull);
      expect(BiologicalSex.fromCode(''), isNull);
      expect(BiologicalSex.fromCode('X'), isNull);
      expect(BiologicalSex.fromCode('m'), isNull);
      expect(BiologicalSex.fromCode('M'), BiologicalSex.male);
    });
  });

  group('PersonalDetails', () {
    test('completo solo con tutti e tre', () {
      expect(PersonalDetails.empty.isComplete, isFalse);
      expect(PersonalDetails.empty.isEmpty, isTrue);

      const partial = PersonalDetails(heightCm: 182, sex: BiologicalSex.male);
      expect(partial.isComplete, isFalse);
      expect(partial.isEmpty, isFalse);
      expect(partial.filledCount, 2);

      final full = partial.copyWith(birthDate: DateTime.utc(1987, 9, 13));
      expect(full.isComplete, isTrue);
      expect(full.filledCount, 3);
    });

    test('l’età si conta sui compleanni, non sugli anni di calendario', () {
      final details = PersonalDetails(birthDate: DateTime.utc(1987, 9, 13));

      // Il giorno prima del compleanno si ha ancora l'età di prima: è la
      // differenza che rende un'età sbagliata di un anno riconoscibile a
      // colpo d'occhio accanto alla data scelta.
      expect(details.ageOn(DateTime.utc(2026, 9, 12)), 38);
      expect(details.ageOn(DateTime.utc(2026, 9, 13)), 39);
      expect(details.ageOn(DateTime.utc(2026, 12, 31)), 39);
      expect(details.ageOn(DateTime.utc(2027, 1, 1)), 39);
    });

    test('senza data di nascita non c’è età da mostrare', () {
      expect(PersonalDetails.empty.ageOn(DateTime.utc(2026, 8, 6)), isNull);
    });

    test('una data futura non produce un’età negativa', () {
      final details = PersonalDetails(birthDate: DateTime.utc(2030, 1, 1));
      expect(details.ageOn(DateTime.utc(2026, 8, 6)), isNull);
    });

    test('dayFrom tiene il giorno civile e lo mette a mezzanotte UTC', () {
      // Il selettore restituisce mezzanotte LOCALE. Salvarla così e
      // rileggerla altrove sposterebbe il compleanno di un giorno a ogni
      // cambio d'ora legale: è lo stesso inciampo già pagato con `birthDate`
      // in `app_profiles`.
      final picked = DateTime(1987, 9, 13);
      final day = PersonalDetails.dayFrom(picked);

      expect(day.isUtc, isTrue);
      expect(day, DateTime.utc(1987, 9, 13));
      expect(day.hour, 0);
    });

    test('due dettagli con gli stessi valori sono uguali', () {
      final first = PersonalDetails(
        heightCm: 182,
        birthDate: DateTime.utc(1987, 9, 13),
        sex: BiologicalSex.male,
      );
      final second = PersonalDetails(
        heightCm: 182,
        birthDate: DateTime.utc(1987, 9, 13),
        sex: BiologicalSex.male,
      );
      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });
  });

  group('PersonalDetailsLimits', () {
    test('la virgola italiana è un separatore decimale, non un errore', () {
      expect(PersonalDetailsLimits.parseHeightCm('182,5'), 182.5);
      expect(PersonalDetailsLimits.parseHeightCm('182.5'), 182.5);
      expect(PersonalDetailsLimits.parseHeightCm('  182 '), 182);
    });

    test('si arrotonda al decimo, come la colonna remota', () {
      // `numeric(5,1)` su Supabase: una precisione maggiore tornerebbe
      // indietro diversa da come è partita.
      expect(PersonalDetailsLimits.parseHeightCm('182,44'), 182.4);
      expect(PersonalDetailsLimits.parseHeightCm('182,46'), 182.5);
    });

    test('quello che non è un numero non è un’altezza', () {
      expect(PersonalDetailsLimits.parseHeightCm('centottantadue'), isNull);
      expect(PersonalDetailsLimits.parseHeightCm(''), isNull);
      expect(PersonalDetailsLimits.parseHeightCm('.'), isNull);
    });

    test('vuoto è valido: significa «non lo dico»', () {
      expect(PersonalDetailsLimits.validateHeight(''), isNull);
      expect(PersonalDetailsLimits.validateHeight('   '), isNull);
    });

    test('fuori scala si spiega con i limiti, non con «non valido»', () {
      expect(PersonalDetailsLimits.validateHeight('182'), isNull);
      expect(PersonalDetailsLimits.validateHeight('49'), contains('50'));
      expect(PersonalDetailsLimits.validateHeight('261'), contains('260'));
      expect(PersonalDetailsLimits.validateHeight('50'), isNull);
      expect(PersonalDetailsLimits.validateHeight('260'), isNull);
      expect(PersonalDetailsLimits.validateHeight('abc'), isNotNull);
    });

    test('i limiti della data sono quelli del CHECK remoto', () {
      // La `0006` pretende `birth_date > date '1900-01-01'`.
      expect(
        PersonalDetailsLimits.earliestBirthDate.isAfter(
          DateTime.utc(1900, 1, 1),
        ),
        isTrue,
      );
      final today = DateTime.utc(2026, 8, 6, 15, 30);
      expect(
        PersonalDetailsLimits.latestBirthDate(today),
        DateTime.utc(2026, 8, 6),
      );
    });
  });
}
