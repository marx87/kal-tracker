import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

class FriendlyDayHeader extends StatelessWidget {
  const FriendlyDayHeader({
    required this.greeting,
    required this.name,
    required this.dateLabel,
    required this.onPreviousDay,
    required this.onPickDay,
    this.onNextDay,
    this.onBackToToday,
    super.key,
  });

  final String greeting;
  final String name;
  final String dateLabel;
  final VoidCallback onPreviousDay;
  final VoidCallback onPickDay;
  final VoidCallback? onNextDay;
  final VoidCallback? onBackToToday;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          container: true,
          header: true,
          label: '$greeting, $name. $dateLabel',
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$greeting, $name!',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    const _GreetingBadge(),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Un pasto alla volta, al tuo ritmo.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedInk),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              key: const Key('previous_day_button'),
              tooltip: 'Giorno precedente',
              onPressed: onPreviousDay,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppPalette.paper,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: AppPalette.outline),
                ),
                child: InkWell(
                  key: const Key('day_picker_button'),
                  onTap: onPickDay,
                  borderRadius: BorderRadius.circular(99),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.calendar_today_rounded,
                          size: 16,
                          color: AppPalette.forest,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            dateLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: AppPalette.forestDark,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('next_day_button'),
              tooltip: 'Giorno successivo',
              onPressed: onNextDay,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
        if (onBackToToday != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('back_to_today_button'),
              onPressed: onBackToToday,
              icon: const Icon(Icons.today_rounded, size: 18),
              label: const Text('Torna a oggi'),
            ),
          ),
      ],
    );
  }
}

class _GreetingBadge extends StatelessWidget {
  const _GreetingBadge();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.08,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: AppPalette.yellowSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(
          Icons.waving_hand_rounded,
          color: AppPalette.yellow,
          size: 25,
        ),
      ),
    );
  }
}
