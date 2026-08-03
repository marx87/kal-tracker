import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DiaryNumberField extends StatelessWidget {
  const DiaryNumberField({
    required this.controller,
    required this.label,
    this.mustBePositive = false,
    this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool mustBePositive;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))],
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label),
      onChanged: onChanged,
      validator: (value) {
        final number = parseDiaryNumber(value ?? '');
        if (number == null) {
          return 'Valore non valido';
        }
        if (mustBePositive ? number <= 0 : number < 0) {
          return mustBePositive ? 'Deve essere > 0' : 'Non può essere negativo';
        }
        return null;
      },
    );
  }
}

double? parseDiaryNumber(String value) {
  final normalized = value.trim().replaceAll(',', '.');
  final parsed = double.tryParse(normalized);
  return parsed != null && parsed.isFinite ? parsed : null;
}

String editableDiaryNumber(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
