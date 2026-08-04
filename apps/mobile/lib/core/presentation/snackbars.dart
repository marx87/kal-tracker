import 'dart:async';

import 'package:flutter/material.dart';

/// Con la navigazione accessibile attiva (TalkBack, ma anche app-locker e
/// password manager che registrano un servizio di accessibilità) Flutter
/// tiene aperte per sempre le SnackBar dotate di azione. Qui la chiusura
/// arriva comunque, lasciando il tempo di toccare «Annulla».
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
showAutoClosingSnackBar(
  ScaffoldMessengerState messenger,
  SnackBar snackBar, {
  Duration closeAfter = const Duration(seconds: 5),
}) {
  final controller = messenger.showSnackBar(snackBar);
  final accessible =
      MediaQuery.maybeOf(messenger.context)?.accessibleNavigation ?? false;
  // Senza navigazione accessibile il timeout di sistema chiude gia' da solo:
  // il timer extra servirebbe solo a far fallire i widget test.
  if (accessible) {
    final timer = Timer(closeAfter, controller.close);
    unawaited(controller.closed.whenComplete(timer.cancel));
  }
  return controller;
}
