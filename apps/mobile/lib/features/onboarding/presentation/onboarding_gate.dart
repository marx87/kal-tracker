import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/onboarding/presentation/onboarding_providers.dart';
import 'package:kal_tracker/features/onboarding/presentation/personal_details_screen.dart';

/// Decide se il primo avvio deve chiedere qualcosa prima di aprire l'app.
///
/// Sta attorno alla shell e non davanti al router perché il benvenuto ha
/// bisogno di un `Navigator` sopra di sé — apre il calendario della data di
/// nascita — e sopra il router non ce n'è ancora nessuno.
///
/// **L'attesa ha un tetto.** La domanda «l'ho già chiesto?» passa da un file, e
/// un file passa da un canale di piattaforma: se il canale non risponde — un
/// plugin rotto, o semplicemente un test, dove i canali non rispondono mai —
/// la risposta non arriva. Un cancello che aspetta per sempre sarebbe un'app
/// che non si apre più, e questo prodotto ha una regola sola più forte di
/// tutte: si apre col Mac spento, senza rete, senza obiettivo. Quindi si
/// aspetta un pugno di fotogrammi con un fondo pulito, e poi si passa comunque.
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({required this.child, super.key});

  /// Quanti fotogrammi si può restare sul fondo pulito prima di lasciar
  /// passare l'app comunque. Venti sono circa un terzo di secondo: coprono
  /// l'apertura del database su un avvio a freddo senza che l'attesa si
  /// noti, e restano pochi abbastanza da non sembrare un blocco.
  static const int warmupFrames = 20;

  final Widget child;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  int _frames = 0;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingNeededProvider);

    // Un controllo che fallisce non è una domanda da fare: si apre l'app.
    if (state.hasError) {
      return widget.child;
    }
    if (state.valueOrNull case final needed?) {
      return needed
          ? const PersonalDetailsScreen(firstRun: true)
          : widget.child;
    }
    if (_frames >= OnboardingGate.warmupFrames) {
      return widget.child;
    }

    // Si conta in fotogrammi e non in millisecondi apposta: un `Timer` nei
    // test scatta solo se qualcuno fa avanzare l'orologio finto, e senza un
    // fotogramma in coda nessuno lo fa. Contando i fotogrammi l'attesa
    // finisce sempre, sia sul telefono sia in prova.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _frames++);
      }
    });
    return const _Warmup();
  }
}

/// Un fondo pieno, non una rotella: l'attesa dura un accesso al database
/// locale, e una rotella che appare e sparisce in due fotogrammi è più
/// fastidiosa dell'attesa che dovrebbe coprire. Il colore lo dà lo `Scaffold`,
/// ed è quello della schermata d'avvio di Android: il passaggio non si vede.
///
/// È uno `Scaffold` e non un semplice fondo colorato per un motivo preciso:
/// in questi fotogrammi il resto dell'app non è ancora costruito, e chi manda
/// una snackbar — l'avviso «proposta pronta da rivedere» delle foto arriva da
/// un provider, quando gli pare — troverebbe un `ScaffoldMessenger` senza
/// nessuno `Scaffold` sotto, che è un'asserzione fallita.
class _Warmup extends StatelessWidget {
  const _Warmup();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      key: Key('onboarding_warmup'),
      body: SizedBox.expand(),
    );
  }
}
