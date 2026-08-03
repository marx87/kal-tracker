import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:kal_tracker/core/notifications/water_reminders.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:timezone/timezone.dart' as tz;

/// Gateway reale su flutter_local_notifications.
///
/// Mai istanziato nei test (che overridano il provider con un fake):
/// tutti i platform channel restano confinati qui.
class FlutterLocalNotificationsWaterGateway implements WaterReminderGateway {
  FlutterLocalNotificationsWaterGateway({
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String _channelId = 'water_reminders';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    // Il fuso è lo stesso dell'app (Europe/Rome via AppTime): niente
    // DateTime.now() locale nella pianificazione.
    AppTime.initialize();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Su iOS il permesso NON si chiede all'avvio: arriva solo dal
        // toggle di Marco, via requestPermission().
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
  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      // Sotto Android 13 non esiste il permesso runtime: null = concesso.
      return await android.requestNotificationsPermission() ?? true;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, sound: true) ?? false;
    }
    return true;
  }

  @override
  Future<void> scheduleDailySlot(WaterReminderSlot slot) async {
    final rome = tz.getLocation(AppTime.zoneName);
    final firstInstance = nextWaterReminderInstance(
      slot.hour,
      tz.TZDateTime.now(rome),
    );
    await _plugin.zonedSchedule(
      id: slot.id,
      title: slot.title,
      body: slot.body,
      scheduledDate: firstInstance,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Promemoria acqua',
          channelDescription: 'Ti ricorda di bere durante la giornata.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Inesatto di proposito: per un promemoria non serve il permesso
      // SCHEDULE_EXACT_ALARM, qualche minuto di scarto va benissimo.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // Ripetizione giornaliera alla stessa ora: sopravvive al riavvio
      // grazie al ScheduledNotificationBootReceiver nel manifest.
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  @override
  Future<void> cancelAll() => _plugin.cancelAll();
}
