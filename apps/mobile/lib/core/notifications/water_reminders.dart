import 'package:kal_tracker/core/notifications/app_notification_ids.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';
import 'package:timezone/timezone.dart' as tz;

/// Promemoria acqua: qui vive tutta la logica pura (slot, orari,
/// messaggi) più il servizio che orchestra il gateway di piattaforma.
///
/// Il plugin vero sta dietro [WaterReminderGateway] così i test girano
/// con un fake e nessun platform channel viene mai toccato.

/// Base degli id notifica: range riservato ai promemoria acqua.
final int waterReminderBaseNotificationId =
    AppNotificationIds.waterReminders.first;

/// Messaggi italiani variati: simpatici ma sobri, mai colpevolizzanti.
const List<({String title, String body})> waterReminderMessages = [
  (
    title: 'Un bicchiere d’acqua?',
    body: 'Piccolo gesto, grande abitudine: 200 ml adesso.',
  ),
  (
    title: 'Pausa idratazione',
    body: 'Un sorso d’acqua aiuta anche la concentrazione.',
  ),
  (
    title: 'L’acqua non si dimentica',
    body: 'Un bicchiere ora e il diario resta in pari.',
  ),
  (
    title: 'Momento acqua',
    body: 'Il corpo lavora meglio idratato: bicchiere alla mano.',
  ),
  (
    title: 'Promemoria gentile',
    body: 'Due dita d’acqua adesso valgono più di un litro stasera.',
  ),
  (
    title: 'Un sorso e via',
    body: 'Bevi qualcosa e segnalo nel diario: è già un passo.',
  ),
];

/// Una notifica pianificata: id stabile, ora del giorno e messaggio.
class WaterReminderSlot {
  const WaterReminderSlot({
    required this.id,
    required this.hour,
    required this.title,
    required this.body,
  });

  final int id;
  final int hour;
  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is WaterReminderSlot &&
      other.id == id &&
      other.hour == hour &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, hour, title, body);
}

/// Calcola gli slot giornalieri: dalla fascia di inizio a quella di fine
/// (estremi inclusi), un promemoria ogni [WaterSettings.reminderIntervalHours]
/// ore. Con i default (2h, 9-21) escono 7 notifiche: 9, 11, 13, …, 21.
List<WaterReminderSlot> waterReminderSlots(WaterSettings settings) {
  final slots = <WaterReminderSlot>[];
  var index = 0;
  for (
    var hour = settings.reminderStartHour;
    hour <= settings.reminderEndHour;
    hour += settings.reminderIntervalHours
  ) {
    final message = waterReminderMessages[index % waterReminderMessages.length];
    slots.add(
      WaterReminderSlot(
        id: AppNotificationIds.waterReminders.at(index),
        hour: hour,
        title: message.title,
        body: message.body,
      ),
    );
    index += 1;
  }
  return slots;
}

/// Prossima occorrenza di [hour] in punto rispetto a [now]: oggi se l'ora
/// deve ancora arrivare, altrimenti domani. L'aritmetica passa dal
/// costruttore TZDateTime così l'ora resta esatta anche a cavallo
/// del cambio ora legale.
tz.TZDateTime nextWaterReminderInstance(int hour, tz.TZDateTime now) {
  final today = tz.TZDateTime(now.location, now.year, now.month, now.day, hour);
  if (today.isAfter(now)) {
    return today;
  }
  return tz.TZDateTime(now.location, now.year, now.month, now.day + 1, hour);
}

/// Il confine col plugin: quattro operazioni, nessun dettaglio di
/// piattaforma. L'implementazione vera è in water_reminders_plugin.dart.
abstract class WaterReminderGateway {
  Future<void> initialize();

  /// Chiede il permesso notifiche (iOS + Android 13). Da chiamare SOLO
  /// quando Marco attiva il toggle, mai all'avvio.
  Future<bool> requestPermission();

  /// Pianifica una notifica che si ripete ogni giorno alla stessa ora.
  Future<void> scheduleDailySlot(WaterReminderSlot slot);

  /// Cancella soltanto gli id posseduti dai promemoria acqua.
  Future<void> cancelSlots(Iterable<int> ids);
}

/// Orchestrazione: attiva (con richiesta permesso), aggiorna, spegne.
class WaterRemindersService {
  WaterRemindersService(this._gateway);

  final WaterReminderGateway _gateway;

  /// Attivazione dal toggle: chiede il permesso adesso e, se concesso,
  /// pianifica tutti gli slot. Ritorna false se il permesso è negato
  /// (in quel caso non pianifica nulla).
  Future<bool> enable(WaterSettings settings) async {
    await _gateway.initialize();
    final granted = await _gateway.requestPermission();
    if (!granted) {
      return false;
    }
    await _scheduleAll(settings);
    return true;
  }

  /// Toggle off: via tutte le notifiche pianificate.
  Future<void> disable() async {
    await _gateway.initialize();
    await _gateway.cancelSlots(AppNotificationIds.waterReminders.all);
  }

  /// Nuovo intervallo o nuova fascia oraria a promemoria già attivi:
  /// ripianifica senza richiedere il permesso. Se i promemoria sono
  /// spenti si limita a cancellare.
  Future<void> applySettings(WaterSettings settings) async {
    await _gateway.initialize();
    if (!settings.remindersEnabled) {
      await _gateway.cancelSlots(AppNotificationIds.waterReminders.all);
      return;
    }
    await _scheduleAll(settings);
  }

  /// All'avvio dell'app: se i promemoria sono attivi li ripianifica
  /// (idempotente, gli id sono stabili). Se sono spenti non tocca nulla,
  /// così il plugin non viene nemmeno inizializzato.
  Future<void> rescheduleOnStartup(WaterSettings settings) async {
    if (!settings.remindersEnabled) {
      return;
    }
    await applySettings(settings);
  }

  Future<void> _scheduleAll(WaterSettings settings) async {
    await _gateway.cancelSlots(AppNotificationIds.waterReminders.all);
    for (final slot in waterReminderSlots(settings)) {
      await _gateway.scheduleDailySlot(slot);
    }
  }
}
