import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const TodayDiaryScreen()),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
