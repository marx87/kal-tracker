import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/sync/sync_auth.dart';
import 'package:kal_tracker/core/sync/sync_engine.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncControllerProvider);
    final auth = ref.watch(syncAuthProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sincronizzazione'),
            Text(
              'Il diario sul cloud, quando vuoi',
              style: TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        key: const Key('sync_list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          if (!auth.configured)
            const _DisabledCard()
          else ...[
            _StatusCard(status: status, auth: auth),
            const SizedBox(height: 14),
            if (status.error != null || auth.error != null) ...[
              _ErrorCard(message: status.error ?? auth.error!),
              const SizedBox(height: 14),
            ],
            if (auth.signedIn)
              _SyncActionsCard(
                status: status,
                busy: auth.busy,
                onSyncNow: () =>
                    ref.read(syncControllerProvider.notifier).syncNow(),
                onSignOut: () => ref.read(syncAuthProvider.notifier).signOut(),
              )
            else
              _SignInCard(
                email: _email,
                password: _password,
                busy: auth.busy,
                onSignIn: _signIn,
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _signIn() async {
    final done = await ref
        .read(syncAuthProvider.notifier)
        .signIn(email: _email.text, password: _password.text);
    if (done && mounted) {
      _password.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Accesso riuscito: sincronizzo.')),
      );
    }
  }
}

class _DisabledCard extends StatelessWidget {
  const _DisabledCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('sync_disabled_card'),
      color: AppPalette.lilacSoft,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cloud non configurato',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Questa copia dell’app funziona tutta offline: i dati restano '
              'solo sul telefono. Per attivare la sincronizzazione serve una '
              'build con le chiavi Supabase.',
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.auth});

  final SyncStatus status;
  final SyncAuthState auth;

  @override
  Widget build(BuildContext context) {
    final lastSync = status.lastSyncAt;
    final lastSyncLabel = lastSync == null
        ? 'Nessuna sincronizzazione ancora.'
        : 'Ultimo sync: ${_moment(AppTime.inRome(lastSync))}';
    final pending = status.pendingCount;
    final pendingLabel = pending == 0
        ? 'Tutto inviato: nessuna modifica in coda.'
        : pending == 1
        ? '1 modifica in coda.'
        : '$pending modifiche in coda.';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: AppPalette.mintSoft,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(
                    status.phase == SyncPhase.syncing
                        ? Icons.cloud_sync_rounded
                        : auth.signedIn
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_off_rounded,
                    color: AppPalette.forest,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Stato della connessione',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        _statusLine(),
                        key: const Key('sync_status_line'),
                        style: const TextStyle(color: AppPalette.mutedInk),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(lastSyncLabel, key: const Key('sync_last_sync')),
            const SizedBox(height: 6),
            Text(pendingLabel, key: const Key('sync_pending_count')),
          ],
        ),
      ),
    );
  }

  String _statusLine() {
    if (status.phase == SyncPhase.syncing) {
      return 'Sincronizzazione in corso…';
    }
    final email = auth.email;
    return email == null
        ? 'Accedi per sincronizzare il diario.'
        : 'Connesso come $email';
  }

  String _moment(DateTime moment) =>
      '${DateFormat('d MMMM y', 'it').format(moment)} alle '
      '${DateFormat('HH:mm', 'it').format(moment)}';
}

class _SyncActionsCard extends StatelessWidget {
  const _SyncActionsCard({
    required this.status,
    required this.busy,
    required this.onSyncNow,
    required this.onSignOut,
  });

  final SyncStatus status;
  final bool busy;
  final Future<void> Function() onSyncNow;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final syncing = status.phase == SyncPhase.syncing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              key: const Key('sync_now_button'),
              onPressed: syncing || busy ? null : onSyncNow,
              icon: syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(syncing ? 'Sincronizzo…' : 'Sincronizza ora'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('sync_sign_out_button'),
              onPressed: busy || syncing ? null : onSignOut,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Disconnetti'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({
    required this.email,
    required this.password,
    required this.busy,
    required this.onSignIn,
  });

  final TextEditingController email;
  final TextEditingController password;
  final bool busy;
  final Future<void> Function() onSignIn;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Accedi', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'Basta una volta: la sessione resta sul telefono e la '
              'sincronizzazione parte da sola.',
              style: TextStyle(color: AppPalette.mutedInk),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('sync_email_field'),
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('sync_password_field'),
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('sync_sign_in_button'),
              onPressed: busy ? null : onSignIn,
              icon: const Icon(Icons.login_rounded),
              label: Text(busy ? 'Accesso in corso…' : 'Accedi'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.coralSoft,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: AppPalette.coral),
            const SizedBox(width: 10),
            Expanded(child: Text(message, key: const Key('sync_error_text'))),
          ],
        ),
      ),
    );
  }
}
