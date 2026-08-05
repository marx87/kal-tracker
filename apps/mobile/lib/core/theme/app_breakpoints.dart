import 'package:flutter/material.dart';

/// La taglia della finestra, non del dispositivo: un telefono ruotato e un
/// tablet stretto possono cadere nella stessa classe, ed è quello che conta
/// per decidere il layout.
enum AppWindowSize {
  /// Telefono in verticale (e tablet in split view stretto).
  compact,

  /// Tablet in verticale: c'è spazio per due colonne e per il rail.
  medium,

  /// Tablet in orizzontale o desktop: rail esteso con le etichette.
  expanded;

  bool get isCompact => this == AppWindowSize.compact;
  bool get isMedium => this == AppWindowSize.medium;
  bool get isExpanded => this == AppWindowSize.expanded;

  /// Da qui in su la navigazione principale lascia la barra in basso e
  /// passa al rail laterale.
  bool get usesNavigationRail => this != AppWindowSize.compact;

  /// Solo in `expanded` il rail può permettersi le etichette per esteso.
  bool get usesExtendedRail => this == AppWindowSize.expanded;
}

/// L'unico posto in cui l'app decide cosa significa «compatto / medio /
/// esteso». Le soglie sono quelle già collaudate nella shell di Gym
/// Tracker sul tablet di Marco: chi costruisce una schermata chiede qui,
/// non reinventa un numero.
abstract final class AppBreakpoints {
  /// Sotto questa larghezza si resta compatti: 840 è dove un tablet in
  /// verticale inizia davvero a reggere due colonne.
  static const double mediumMin = 840;

  /// Sopra questa il rail può stare esteso senza rubare spazio ai contenuti.
  static const double expandedMin = 1180;

  static AppWindowSize fromWidth(double width) {
    if (width >= expandedMin) {
      return AppWindowSize.expanded;
    }
    if (width >= mediumMin) {
      return AppWindowSize.medium;
    }
    return AppWindowSize.compact;
  }

  /// Taglia della finestra intera. Dentro un pannello di un layout a due
  /// colonne serve invece [AdaptiveLayout], che misura lo spazio reale.
  static AppWindowSize of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  /// Margini di pagina: crescono con lo spazio, ma senza esagerare, perché
  /// il respiro vero su tablet lo dà [contentMaxWidth].
  static EdgeInsets pagePadding(AppWindowSize size) => switch (size) {
    AppWindowSize.compact => const EdgeInsets.fromLTRB(16, 0, 16, 24),
    AppWindowSize.medium => const EdgeInsets.fromLTRB(24, 4, 24, 32),
    AppWindowSize.expanded => const EdgeInsets.fromLTRB(32, 8, 32, 40),
  };

  /// Spazio tra le colonne e tra le card affiancate.
  static double gutter(AppWindowSize size) => switch (size) {
    AppWindowSize.compact => 12,
    AppWindowSize.medium => 16,
    AppWindowSize.expanded => 20,
  };

  /// Quante colonne regge una griglia di card.
  static int columns(AppWindowSize size) => switch (size) {
    AppWindowSize.compact => 1,
    AppWindowSize.medium => 2,
    AppWindowSize.expanded => 3,
  };

  /// Larghezza massima di una colonna di contenuto. Su tablet una riga di
  /// testo larga tutto lo schermo è illeggibile: si smette di crescere e si
  /// centra.
  static double contentMaxWidth(AppWindowSize size) => switch (size) {
    AppWindowSize.compact => double.infinity,
    AppWindowSize.medium => 720,
    AppWindowSize.expanded => 880,
  };
}

/// Ricostruisce in base allo spazio **davvero disponibile**, non allo
/// schermo: così funziona anche dentro un pannello, un foglio o una
/// colonna del layout esteso.
class AdaptiveLayout extends StatelessWidget {
  const AdaptiveLayout({required this.builder, super.key});

  final Widget Function(BuildContext context, AppWindowSize size) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Con vincoli orizzontali illimitati (dentro una Row scorrevole)
        // non c'è una larghezza da misurare: si resta compatti.
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return builder(context, AppBreakpoints.fromWidth(width));
      },
    );
  }
}

/// Centra il contenuto e ne limita la larghezza secondo la taglia corrente.
/// Una riga in più attorno a una lista e la schermata è già a posto sul
/// tablet.
class AdaptiveContent extends StatelessWidget {
  const AdaptiveContent({
    required this.child,
    this.padded = false,
    this.alignment = Alignment.topCenter,
    super.key,
  });

  final Widget child;

  /// Applica anche i margini di pagina della taglia corrente.
  final bool padded;

  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AdaptiveLayout(
      builder: (context, size) {
        final maxWidth = AppBreakpoints.contentMaxWidth(size);
        final content = padded
            ? Padding(padding: AppBreakpoints.pagePadding(size), child: child)
            : child;
        if (!maxWidth.isFinite) {
          return content;
        }
        return Align(
          alignment: alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: content,
          ),
        );
      },
    );
  }
}
