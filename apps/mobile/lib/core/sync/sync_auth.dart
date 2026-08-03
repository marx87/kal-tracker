import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/sync/sync_engine.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';

/// Stato della sessione Supabase di Marco. Nessuna registrazione dall'app:
/// solo accesso con un account creato a mano sul progetto.
class SyncAuthState {
  const SyncAuthState({
    required this.configured,
    this.email,
    this.busy = false,
    this.error,
  });

  const SyncAuthState.notConfigured()
    : configured = false,
      email = null,
      busy = false,
      error = null;

  final bool configured;
  final String? email;
  final bool busy;
  final String? error;

  bool get signedIn => email != null;

  SyncAuthState copyWith({
    String? email,
    bool clearEmail = false,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => SyncAuthState(
    configured: configured,
    email: clearEmail ? null : (email ?? this.email),
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

class SyncAuthController extends Notifier<SyncAuthState> {
  bool _disposed = false;

  @override
  SyncAuthState build() {
    final config = ref.watch(appConfigProvider);
    if (!config.hasSupabaseConfiguration) {
      return const SyncAuthState.notConfigured();
    }
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    _loadAccount();
    return const SyncAuthState(configured: true);
  }

  Future<void> _loadAccount() async {
    try {
      final account = await ref.read(syncGatewayProvider).currentAccount();
      if (_disposed || account == null) {
        return;
      }
      state = state.copyWith(email: account.email);
    } on Object {
      return;
    }
  }

  Future<bool> signIn({required String email, required String password}) async {
    final cleanEmail = email.trim();
    if (cleanEmail.isEmpty || password.isEmpty) {
      state = state.copyWith(error: 'Servono email e password.');
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final account = await ref
          .read(syncGatewayProvider)
          .signIn(email: cleanEmail, password: password);
      if (_disposed) {
        return true;
      }
      state = state.copyWith(email: account.email, busy: false);
      // La sessione è persistita da supabase_flutter: da qui in poi
      // il motore può lavorare da solo.
      await ref.read(syncControllerProvider.notifier).syncNow();
      return true;
    } on SyncGatewayException catch (error) {
      if (!_disposed) {
        state = state.copyWith(busy: false, error: error.message);
      }
      return false;
    } on Object {
      if (!_disposed) {
        state = state.copyWith(
          busy: false,
          error: 'Accesso non riuscito: riprova tra poco.',
        );
      }
      return false;
    }
  }

  /// Chiamato dal motore quando il server non riconosce più la sessione:
  /// l'email sparisce e il messaggio invita a riaccedere.
  void sessionExpired() {
    if (_disposed || !state.signedIn) {
      return;
    }
    state = state.copyWith(
      clearEmail: true,
      busy: false,
      error:
          'La sessione è scaduta: accedi di nuovo per riprendere '
          'la sincronizzazione.',
    );
  }

  Future<void> signOut() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      await ref.read(syncGatewayProvider).signOut();
    } finally {
      if (!_disposed) {
        state = state.copyWith(busy: false, clearEmail: true);
      }
    }
  }
}

final syncAuthProvider = NotifierProvider<SyncAuthController, SyncAuthState>(
  SyncAuthController.new,
);
