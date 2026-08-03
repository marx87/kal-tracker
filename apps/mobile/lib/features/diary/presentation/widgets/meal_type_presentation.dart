import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';

extension MealTypePresentation on MealType {
  String get label => switch (this) {
    MealType.breakfast => 'Colazione',
    MealType.lunch => 'Pranzo',
    MealType.dinner => 'Cena',
    MealType.snack => 'Spuntini',
  };

  IconData get icon => switch (this) {
    MealType.breakfast => Icons.wb_sunny_outlined,
    MealType.lunch => Icons.light_mode_outlined,
    MealType.dinner => Icons.nightlight_outlined,
    MealType.snack => Icons.eco_outlined,
  };

  Color get accent => switch (this) {
    MealType.breakfast => AppPalette.yellow,
    MealType.lunch => AppPalette.coral,
    MealType.dinner => AppPalette.lilac,
    MealType.snack => AppPalette.leaf,
  };

  Color get softColor => switch (this) {
    MealType.breakfast => AppPalette.yellowSoft,
    MealType.lunch => AppPalette.coralSoft,
    MealType.dinner => AppPalette.lilacSoft,
    MealType.snack => AppPalette.mint,
  };
}
