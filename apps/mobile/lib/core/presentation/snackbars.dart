import 'dart:async';

import 'package:flutter/material.dart';

/// Su questo Flutter (Material 3) le SnackBar dotate di azione non si
/// chiudono MAI da sole, su qualunque dispositivo: il timeout di sistema
/// vale solo per quelle senza azione. Qui la chiusura arriva comunque,
/// lasciando il tempo di toccare «Annulla».
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
showAutoClosingSnackBar(
  ScaffoldMessengerState messenger,
  SnackBar snackBar, {
  Duration closeAfter = const Duration(seconds: 5),
}) {
  final controller = messenger.showSnackBar(snackBar);
  final timer = Timer(closeAfter, controller.close);
  unawaited(controller.closed.whenComplete(timer.cancel));
  return controller;
}
