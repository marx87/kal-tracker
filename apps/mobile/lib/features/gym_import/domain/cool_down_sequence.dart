/// Copia verbatim di `kCoolDownSequence` di Gym Tracker: slug, nome, durata e
/// suggerimento. NON riscrivere i nomi a mano — i tre che erano stati
/// riscritti ('Torsione spinale', 'Allungamento femorali') non corrispondono
/// né al sorgente né allo storico, e `coolDownAsWorkoutExercises()` continua a
/// registrare i nomi veri: lo stesso slug finirebbe con due nomi diversi nello
/// stesso database, per sempre.
class CoolDownItem {
  const CoolDownItem({
    required this.slug,
    required this.name,
    required this.durationSec,
    this.hint,
  });

  final String slug;
  final String name;
  final int durationSec;
  final String? hint;

  static const int restSec = 10;
}

const List<CoolDownItem> kCoolDownSequence = [
  CoolDownItem(
    slug: 'cd-childpose',
    name: 'Child pose',
    durationSec: 40,
    hint: 'Talloni sotto ai glutei, braccia distese, fronte a terra. Respira.',
  ),
  CoolDownItem(
    slug: 'cd-cobra',
    name: 'Cobra',
    durationSec: 30,
    hint: 'Prono: spingi il torace verso l\'alto. Allunga l\'addome.',
  ),
  CoolDownItem(
    slug: 'cd-downdog',
    name: 'Downward dog',
    durationSec: 40,
    hint: 'V rovesciata. Spingi i talloni verso terra, respira profondo.',
  ),
  CoolDownItem(
    slug: 'cd-pigeon-l',
    name: 'Piccione (gamba sx avanti)',
    durationSec: 40,
    hint: 'Allungamento gluteo + anca sinistra.',
  ),
  CoolDownItem(
    slug: 'cd-pigeon-r',
    name: 'Piccione (gamba dx avanti)',
    durationSec: 40,
    hint: 'Allungamento gluteo + anca destra.',
  ),
  CoolDownItem(
    slug: 'cd-spinaltwist-l',
    name: 'Torsione supina (sx)',
    durationSec: 30,
    hint: 'Sdraiato, ginocchio che scavalca a sinistra.',
  ),
  CoolDownItem(
    slug: 'cd-spinaltwist-r',
    name: 'Torsione supina (dx)',
    durationSec: 30,
    hint: 'Sdraiato, ginocchio che scavalca a destra.',
  ),
  CoolDownItem(
    slug: 'cd-hamstring',
    name: 'Ischiocrurali (half splits)',
    durationSec: 40,
    hint: 'Gamba tesa avanti, busto verso il piede. Alterna 20s per lato.',
  ),
];
