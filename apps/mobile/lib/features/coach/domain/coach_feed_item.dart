import 'package:flutter/foundation.dart';

enum CoachFeedSource { deterministic, ai }

@immutable
class CoachFeedItem {
  const CoachFeedItem({
    required this.id,
    required this.kind,
    required this.source,
    required this.title,
    required this.body,
    required this.occurredAt,
    this.externalId,
    this.actionLabel,
    this.actionPath,
    this.readAt,
    this.dismissedAt,
  });

  final String id;
  final String kind;
  final CoachFeedSource source;
  final String? externalId;
  final String title;
  final String body;
  final String? actionLabel;
  final String? actionPath;
  final DateTime occurredAt;
  final DateTime? readAt;
  final DateTime? dismissedAt;

  bool get isRead => readAt != null;
  bool get isDismissed => dismissedAt != null;
}
