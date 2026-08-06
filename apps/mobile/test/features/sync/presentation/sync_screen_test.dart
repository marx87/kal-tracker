import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_engine.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/sync/sync_state_store.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/sync/presentation/sync_screen.dart';
import 'package:kal_tracker/features/wellbeing/data/wellbeing_repository.dart';

class FakeSyncGateway implements SyncGateway {
  FakeSyncGateway({this.account});

  SyncAccount? account;
  final List<SyncMutation> received = [];
  List<RemoteChange> changes = [];
  SyncGatewayException? pushError;

  @override
  Future<SyncAccount?> currentAccount() async => account;

  @override
  Future<SyncAccount> signIn({
    required String email,
    required String password,
  }) async {
    account = SyncAccount(userId: 'user-1', email: email);
    return account!;
  }

  @override
  Future<void> signOut() async {
    account = null;
  }

  @override
  Future<void> pushMutation(SyncMutation mutation) async {
    received.add(mutation);
    final failure = pushError;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<List<RemoteChange>> fetchChanges({
    required int afterChangeId,
    int limit = 200,
  }) async => const [];
}

const _cloudConfig = AppConfig(
  supabaseUrl: 'https://esempio.supabase.co',
  supabasePublishableKey: 'sb_publishable_finta',
  otaManifestUrl: '',
  otaPublicKeyBase64: '',
  otaKeyId: 'ota-test',
  otaChannel: 'personal',
);

void main() {
  testWidgets('senza configurazione mostra solo la scheda offline', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final stateDir = Directory.systemTemp.createTempSync('kal-sync-screen');
    addTearDown(() => stateDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      _app(
        database: database,
        config: const AppConfig.offline(),
        gateway: FakeSyncGateway(),
        stateDir: stateDir,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sync_disabled_card')), findsOneWidget);
    expect(find.byKey(const Key('sync_now_button')), findsNothing);
    expect(find.byKey(const Key('sync_email_field')), findsNothing);

    await _disposeApp(tester, database);
  });

  testWidgets('mostra la coda e sincronizza al tocco del pulsante', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = (await LocalProfileRepository(
      database,
    ).getOrCreateMarco()).id;
    await WellbeingRepository(database).addWater(
      profileId: profileId,
      milliliters: 250,
      loggedAt: DateTime(2026, 8, 3, 8),
    );
    final gateway = FakeSyncGateway(
      account: const SyncAccount(userId: 'user-1', email: 'marco@test.it'),
    );
    final stateDir = Directory.systemTemp.createTempSync('kal-sync-screen');
    addTearDown(() => stateDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      _app(
        database: database,
        config: _cloudConfig,
        gateway: gateway,
        stateDir: stateDir,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('sync_status_line'))).data,
      'Connesso come marco@test.it',
    );
    expect(find.text('1 modifica in coda.'), findsOneWidget);
    expect(find.text('Nessuna sincronizzazione ancora.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sync_now_button')));
    await tester.pumpAndSettle();

    expect(gateway.received, hasLength(1));
    expect(gateway.received.single.entityType, 'water_log');
    expect(
      find.text('Tutto inviato: nessuna modifica in coda.'),
      findsOneWidget,
    );
    expect(find.textContaining('Ultimo sync:'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la sessione scaduta riporta all’accesso con un avviso', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = (await LocalProfileRepository(
      database,
    ).getOrCreateMarco()).id;
    await WellbeingRepository(database).addWater(
      profileId: profileId,
      milliliters: 250,
      loggedAt: DateTime(2026, 8, 3, 8),
    );
    final gateway =
        FakeSyncGateway(
            account: const SyncAccount(
              userId: 'user-1',
              email: 'marco@test.it',
            ),
          )
          ..pushError = const SyncGatewayException(
            'La sessione è scaduta: accedi di nuovo.',
            authRequired: true,
          );
    final stateDir = Directory.systemTemp.createTempSync('kal-sync-screen');
    addTearDown(() => stateDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      _app(
        database: database,
        config: _cloudConfig,
        gateway: gateway,
        stateDir: stateDir,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('sync_status_line'))).data,
      'Connesso come marco@test.it',
    );

    await tester.tap(find.byKey(const Key('sync_now_button')));
    await tester.pumpAndSettle();

    // Niente più "Connesso come": la schermata torna all'accesso e spiega
    // in italiano cosa fare.
    expect(
      tester.widget<Text>(find.byKey(const Key('sync_status_line'))).data,
      'Accedi per sincronizzare il diario.',
    );
    expect(find.byKey(const Key('sync_email_field')), findsOneWidget);
    expect(find.byKey(const Key('sync_now_button')), findsNothing);
    expect(
      find.text(
        'La sessione è scaduta: accedi di nuovo per riprendere '
        'la sincronizzazione.',
      ),
      findsOneWidget,
    );

    await _disposeApp(tester, database);
  });

  testWidgets('da disconnesso si accede con email e password', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakeSyncGateway();
    final stateDir = Directory.systemTemp.createTempSync('kal-sync-screen');
    addTearDown(() => stateDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      _app(
        database: database,
        config: _cloudConfig,
        gateway: gateway,
        stateDir: stateDir,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('sync_status_line'))).data,
      'Accedi per sincronizzare il diario.',
    );

    await tester.enterText(
      find.byKey(const Key('sync_email_field')),
      'marco@test.it',
    );
    await tester.enterText(
      find.byKey(const Key('sync_password_field')),
      'una-password',
    );
    tester.testTextInput.hide();
    await tester.tap(find.byKey(const Key('sync_sign_in_button')));
    await tester.pumpAndSettle();

    expect(gateway.account, isNotNull);
    expect(
      tester.widget<Text>(find.byKey(const Key('sync_status_line'))).data,
      'Connesso come marco@test.it',
    );
    expect(find.byKey(const Key('sync_sign_out_button')), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('sul tablet largo i campi restano in una colonna leggibile', (
    tester,
  ) async {
    // Email e password larghe 1706 dp non aiutano nessuno: il contenuto si
    // ferma alla colonna leggibile e si centra.
    AppTime.initialize();
    tester.view.physicalSize = const Size(1706, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = AppDatabase(NativeDatabase.memory());
    final stateDir = Directory.systemTemp.createTempSync('kal-sync-screen');
    addTearDown(() => stateDir.deleteSync(recursive: true));

    await tester.pumpWidget(
      _app(
        database: database,
        config: _cloudConfig,
        gateway: FakeSyncGateway(),
        stateDir: stateDir,
      ),
    );
    await tester.pumpAndSettle();

    final width = tester.getSize(find.byKey(const Key('sync_list'))).width;
    expect(width, AppBreakpoints.contentMaxWidth(AppWindowSize.expanded));
    expect(width, lessThan(1706));
    // Centrata, non appiccicata al bordo sinistro.
    expect(
      tester.getTopLeft(find.byKey(const Key('sync_list'))).dx,
      greaterThan(0),
    );

    await _disposeApp(tester, database);
  });

  testWidgets('dai Progressi si raggiunge la sincronizzazione', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appConfigProvider.overrideWithValue(const AppConfig.offline()),
        ],
        child: const KalTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nav_body')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body_open_progress_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_sync_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sync_list')), findsOneWidget);
    expect(find.byKey(const Key('sync_disabled_card')), findsOneWidget);

    await _disposeApp(tester, database);
  });
}

Widget _app({
  required AppDatabase database,
  required AppConfig config,
  required FakeSyncGateway gateway,
  required Directory stateDir,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(config),
    syncGatewayProvider.overrideWithValue(gateway),
    syncStateStoreProvider.overrideWithValue(
      SyncStateStore(stateDirectory: () async => stateDir),
    ),
  ],
  child: MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: const SyncScreen(),
  ),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
