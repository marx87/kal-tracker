import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/notifications/water_reminders.dart';
import 'package:kal_tracker/core/notifications/water_reminders_plugin.dart';

/// Gateway di piattaforma per i promemoria acqua.
///
/// Nei test va SEMPRE overridato con un fake: l'istanza reale parla
/// coi platform channel che nei widget test non esistono.
final waterReminderGatewayProvider = Provider<WaterReminderGateway>(
  (ref) => FlutterLocalNotificationsWaterGateway(),
);

final waterRemindersServiceProvider = Provider<WaterRemindersService>(
  (ref) => WaterRemindersService(ref.watch(waterReminderGatewayProvider)),
);
