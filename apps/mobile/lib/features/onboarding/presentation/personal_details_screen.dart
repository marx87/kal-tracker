import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/onboarding/domain/personal_details.dart';
import 'package:kal_tracker/features/onboarding/presentation/onboarding_providers.dart';

/// Altezza, data di nascita e sesso: la stessa schermata al primo avvio e
/// quando si vuole correggerli.
///
/// È una schermata sola e non due perché i campi, le convalide e i limiti
/// sono gli stessi: cambiano la cornice (un benvenuto senza barra in alto
/// contro una pagina con il tasto indietro) e la via d'uscita — al primo
/// avvio c'è «lo faccio dopo», dopo c'è la freccia.
///
/// **Niente qui è obbligatorio.** Diario, allenamenti, acqua e peso funzionano
/// identici senza questi tre dati; restano indietro solo BMI, metabolismo
/// basale e le percentuali della bilancia. Un'app che non parte finché non le
/// hai risposto tiene in ostaggio l'utente per un grafico.
class PersonalDetailsScreen extends ConsumerWidget {
  const PersonalDetailsScreen({this.firstRun = false, super.key});

  /// Vero quando è il benvenuto del primo avvio.
  final bool firstRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(personalDetailsProvider);

    return details.when(
      data: (value) => _PersonalDetailsForm(initial: value, firstRun: firstRun),
      loading: () => const Scaffold(
        body: Center(
          key: Key('personal_details_loading'),
          child: CircularProgressIndicator(),
        ),
      ),
      // Se il profilo non si legge si parte da vuoto invece di mostrare un
      // errore: questa schermata serve a scrivere, non a leggere, e un campo
      // vuoto è un punto di partenza legittimo.
      error: (error, stackTrace) => _PersonalDetailsForm(
        initial: PersonalDetails.empty,
        firstRun: firstRun,
      ),
    );
  }
}

class _PersonalDetailsForm extends ConsumerStatefulWidget {
  const _PersonalDetailsForm({required this.initial, required this.firstRun});

  final PersonalDetails initial;
  final bool firstRun;

  @override
  ConsumerState<_PersonalDetailsForm> createState() =>
      _PersonalDetailsFormState();
}

class _PersonalDetailsFormState extends ConsumerState<_PersonalDetailsForm> {
  static final _fullDay = DateFormat('d MMMM y', 'it');
  static final _height = NumberFormat('#,##0.#', 'it');

  final _formKey = GlobalKey<FormState>();
  final _heightController = TextEditingController();

  DateTime? _birthDate;
  BiologicalSex? _sex;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial.heightCm case final height?) {
      _heightController.text = _height.format(height);
    }
    _birthDate = initial.birthDate;
    _sex = initial.sex;
  }

  @override
  void dispose() {
    _heightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Scaffold(
      appBar: widget.firstRun
          ? null
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Dati personali'),
                  Text(
                    'Altezza, nascita e sesso',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
      body: SafeArea(
        child: AdaptiveContent(
          child: Form(
            key: _formKey,
            child: ListView(
              key: const Key('personal_details_list'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                if (widget.firstRun) ...[
                  // La via d'uscita sta in ALTO, prima di tutto il resto. In
                  // fondo alla pagina sarebbe sotto la piega su uno schermo
                  // piccolo — e ancora più giù col testo ingrandito — e una
                  // via d'uscita che si trova solo scorrendo non è una scelta
                  // offerta, è una scelta nascosta.
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const Key('personal_details_skip_button'),
                      onPressed: _saving ? null : _skip,
                      child: const Text('Lo faccio dopo'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const _WelcomeHeader(),
                  const SizedBox(height: 22),
                ],
                _HeightField(controller: _heightController),
                const SizedBox(height: 16),
                _BirthDateField(
                  value: _birthDate,
                  format: _fullDay.format,
                  onPick: _pickBirthDate,
                ),
                const SizedBox(height: 16),
                _SexField(
                  value: _sex,
                  onChanged: (value) => setState(() => _sex = value),
                ),
                const SizedBox(height: 26),
                FilledButton(
                  key: const Key('personal_details_save_button'),
                  onPressed: _saving ? null : _save,
                  child: Text(widget.firstRun ? 'Salva e inizia' : 'Salva'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickBirthDate() async {
    final today = AppTime.nowInRome();
    final picked = await showDatePicker(
      context: context,
      // Senza una data iniziale il calendario si apre su oggi e per arrivare
      // agli anni Ottanta servono quarant'anni di frecce: si parte da una
      // data plausibile e si corregge, che è un tocco solo sul selettore
      // degli anni.
      initialDate: _birthDate ?? DateTime.utc(today.year - 35, 1, 1),
      firstDate: PersonalDetailsLimits.earliestBirthDate,
      lastDate: PersonalDetailsLimits.latestBirthDate(today),
      helpText: 'Quando sei nato',
      // Il calendario si apre già sugli anni: il mese giusto di quarant'anni
      // fa non lo si trova scorrendo.
      initialDatePickerMode: DatePickerMode.year,
    );
    if (picked == null) {
      return;
    }
    setState(() => _birthDate = PersonalDetails.dayFrom(picked));
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final raw = _heightController.text.trim();
    final details = PersonalDetails(
      heightCm: raw.isEmpty ? null : PersonalDetailsLimits.parseHeightCm(raw),
      birthDate: _birthDate,
      sex: _sex,
    );

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(onboardingControllerProvider).save(details);
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
      }
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Non riesco a salvare: i dati restano quelli di prima.',
          ),
        ),
      );
      return;
    }
    if (widget.firstRun) {
      // Il gate si accorge da solo che la domanda è stata fatta e lascia
      // passare l'app: non c'è niente da chiudere.
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(_confirmation(details))));
    if (navigator.canPop()) {
      navigator.pop();
    } else if (mounted) {
      setState(() => _saving = false);
    }
  }

  /// Cosa dire dopo il salvataggio: non «fatto», ma cosa cambia adesso.
  String _confirmation(PersonalDetails details) {
    if (details.isEmpty) {
      return 'Dati svuotati. BMI e metabolismo restano fuori dai conti.';
    }
    if (details.isComplete) {
      return 'Salvati: da adesso BMI, metabolismo e composizione hanno tutto '
          'quello che serve.';
    }
    return 'Salvati. Ne manca ancora qualcuno, e alcune formule restano a '
        'metà.';
  }

  Future<void> _skip() async {
    setState(() => _saving = true);
    try {
      await ref.read(onboardingControllerProvider).skip();
    } on Object {
      // Saltare non deve poter fallire: al peggio la domanda torna al
      // prossimo avvio.
    }
    if (mounted) {
      setState(() => _saving = false);
    }
  }
}

class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Decorativo: il lettore di schermo deve sentire il titolo, non
        // «icona».
        ExcludeSemantics(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(
                Icons.straighten_rounded,
                size: 32,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Semantics(
          header: true,
          child: Text(
            'Prima di iniziare',
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tre dati e non te li chiedo più: altezza, data di nascita e sesso. '
          'Servono a BMI, metabolismo basale e alle percentuali della '
          'bilancia — senza, Corpo e Obiettivo restano a metà.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: accents.mutedInk,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Se preferisci, salta: diario, allenamenti, acqua e peso funzionano '
          'lo stesso. Li puoi aggiungere quando vuoi da Corpo → Progressi → '
          'Dati personali.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: accents.mutedInk,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// Campo altezza. Accetta la virgola, che è come si scrivono i decimali su
/// una tastiera italiana.
class _HeightField extends StatelessWidget {
  const _HeightField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: const Key('personal_details_height_field'),
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: 'Altezza',
        suffixText: 'cm',
        helperText: 'Serve al BMI e alle formule della bilancia.',
        helperMaxLines: 2,
        errorMaxLines: 2,
      ),
      validator: (value) => PersonalDetailsLimits.validateHeight(value ?? ''),
    );
  }
}

/// La data di nascita non è un campo di testo: è un bottone che apre il
/// calendario. Scritta a mano sarebbe tre convalide (formato, esistenza,
/// intervallo) e un errore di battitura silenzioso.
class _BirthDateField extends StatelessWidget {
  const _BirthDateField({
    required this.value,
    required this.format,
    required this.onPick,
  });

  final DateTime? value;
  final String Function(DateTime) format;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accents = AppAccents.of(context);
    final today = AppTime.nowInRome();
    final age = PersonalDetails(birthDate: value).ageOn(today);
    final text = value == null
        ? 'Scegli una data'
        : '${format(value!)}${age == null ? '' : ' · $age anni'}';

    // Un nodo solo — etichetta, valore, azione — al posto di «testo, testo,
    // icona». `onTap` va dichiarato QUI e non solo sull'`InkWell`: con
    // `excludeSemantics` l'azione del figlio sparisce, e resterebbe un
    // bottone che il lettore di schermo annuncia ma non sa premere.
    return Semantics(
      button: true,
      label: 'Data di nascita',
      value: value == null ? 'non indicata' : text,
      onTap: onPick,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('personal_details_birth_date_field'),
          onTap: onPick,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            // 56 è l'altezza di un campo di testo del tema: la riga deve
            // sembrare uno di loro, e non scendere mai sotto il bersaglio
            // da 48.
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.cardTheme.color ?? scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.outline),
            ),
            child: Row(
              children: [
                Icon(Icons.event_rounded, size: 20, color: accents.mutedInk),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Data di nascita',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accents.mutedInk,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(text, style: theme.textTheme.titleSmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: accents.mutedInk),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SexField extends StatelessWidget {
  const _SexField({required this.value, required this.onChanged});

  final BiologicalSex? value;
  final ValueChanged<BiologicalSex?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sesso', style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          'Le formule del metabolismo e della bioimpedenza hanno due '
          'parametrizzazioni: qui si sceglie quale usare.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: accents.mutedInk,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        // In una `Wrap` e non in una `Row`: al 150% di testo due bottoni
        // affiancati non ci starebbero, e qui vanno a capo invece di
        // traboccare.
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final option in BiologicalSex.values)
              _SexOption(
                option: option,
                selected: option == value,
                onSelected: () => onChanged(option),
              ),
          ],
        ),
        if (value != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('personal_details_clear_sex_button'),
              onPressed: () => onChanged(null),
              child: const Text('Preferisco non dirlo'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Una delle due scelte. È una `ChoiceChip` cresciuta fino al bersaglio da 48
/// e non un `SegmentedButton` perché quello divide la larghezza in parti
/// fisse: con il testo al 150% le etichette ci finiscono tagliate.
class _SexOption extends StatelessWidget {
  const _SexOption({
    required this.option,
    required this.selected,
    required this.onSelected,
  });

  final BiologicalSex option;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: ChoiceChip(
        key: Key('personal_details_sex_${option.code}'),
        selected: selected,
        // La spunta è il segnale ridondante al colore: chi non distingue il
        // verde vede comunque quale delle due è scelta.
        showCheckmark: true,
        label: Text(option.label),
        labelPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        onSelected: (_) => onSelected(),
      ),
    );
  }
}
