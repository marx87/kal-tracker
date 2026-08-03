import 'package:flutter/material.dart';

/// I colori dell'acqua, in un posto solo: prima erano hex inline in
/// ProgressScreen. Restano fuori da AppPalette perché sono un accento
/// tematico dell'acqua, non colori di sistema.
abstract final class WaterPalette {
  /// Il blu principale dell'acqua (già usato in ProgressScreen).
  static const deep = Color(0xFF397CB3);

  /// Sfondo tenue per pill e barre.
  static const soft = Color(0xFFE0F0FC);

  /// Interno del bicchiere ancora vuoto.
  static const mist = Color(0xFFF3FAFF);

  /// Cresta dell'onda e bollicine.
  static const crest = Color(0xFF7FB3DC);
}
