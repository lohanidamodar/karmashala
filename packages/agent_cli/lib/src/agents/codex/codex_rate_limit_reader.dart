import 'dart:convert';
import 'dart:io';

import '../data/usage_throttle.dart';
import '../domain/agent_usage.dart';
import '../domain/rate_limit_record.dart';

/// How much of a rollout's end is searched. A `token_count` record is under
/// 1.5 KB and is written after every model call, so the newest is near EOF.
const int kCodexRateLimitTailBytes = 64 * 1024;

const String _tokenCountMarker = '"type":"token_count"';
const String _rateLimitsMarker = '"rate_limits"';

/// The newest rate-limit block in the rollout at [filePath], or null when the
/// file is missing, unreadable, or its tail holds none. Reads one bounded tail.
Future<RateLimitRecord?> readCodexRateLimits(String filePath) async {
  try {
    final file = File(filePath);
    final length = await file.length();
    final start = length > kCodexRateLimitTailBytes
        ? length - kCodexRateLimitTailBytes
        : 0;
    final bytes = await file
        .openRead(start, length)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    return parseCodexRateLimitTail(utf8.decode(bytes, allowMalformed: true));
  } on FileSystemException {
    return null;
  }
}

/// The newest rate-limit block among [tail]'s lines, newest last. A first line
/// cut by the tail window fails to decode and is skipped like any other.
RateLimitRecord? parseCodexRateLimitTail(String tail) {
  final lines = const LineSplitter().convert(tail);
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i];
    if (!line.contains(_tokenCountMarker)) continue;
    if (!line.contains(_rateLimitsMarker)) continue;
    final snapshot = _parseRecord(line);
    if (snapshot != null) return snapshot;
  }
  return null;
}

RateLimitRecord? _parseRecord(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final payload = decoded['payload'];
  if (payload is! Map || payload['type'] != 'token_count') return null;
  final limits = payload['rate_limits'];
  if (limits is! Map) return null;

  final stamp = decoded['timestamp'];
  final recordedAt = stamp is String ? DateTime.tryParse(stamp)?.toUtc() : null;
  final windows = <UsageWindow>[
    for (final key in const ['primary', 'secondary'])
      ?_window(limits[key], recordedAt),
  ];
  final reached = limits['rate_limit_reached_type'];
  return RateLimitRecord(
    windows: windows,
    reachedType: reached is String && reached.isNotEmpty ? reached : null,
    recordedAt: recordedAt,
  );
}

/// Both schema generations: `resets_at` in epoch seconds, and the older
/// `resets_in_seconds`, which only means something beside the record's time.
UsageWindow? _window(Object? raw, DateTime? recordedAt) {
  if (raw is! Map) return null;
  final percent = raw['used_percent'];
  if (percent is! num) return null;
  final minutes = raw['window_minutes'];
  final span = minutes is num ? Duration(minutes: minutes.round()) : null;

  DateTime? resetsAt;
  final at = raw['resets_at'];
  final inSeconds = raw['resets_in_seconds'];
  if (at is num) {
    resetsAt = DateTime.fromMillisecondsSinceEpoch(
      (at * 1000).round(),
      isUtc: true,
    );
  } else if (inSeconds is num && recordedAt != null) {
    resetsAt = recordedAt.add(Duration(seconds: inSeconds.round()));
  }
  return UsageWindow(
    label: _labelFor(span),
    percent: percent.toDouble(),
    resetsAt: resetsAt,
    span: _nominal(span),
  );
}

/// Codex rounds `window_minutes` (299, 10079), so the nominal period is the
/// nearest known one — and the label the usage endpoint's windows carry.
Duration? _nominal(Duration? span) {
  if (span == null) return null;
  for (final known in const [kUsageFiveHourWindow, kUsageSevenDayWindow]) {
    if ((span - known).abs() <= known * 0.05) return known;
  }
  return span;
}

String _labelFor(Duration? span) {
  final nominal = _nominal(span);
  if (nominal == kUsageFiveHourWindow) return '5-hour';
  if (nominal == kUsageSevenDayWindow) return '7-day';
  if (nominal == null) return 'limit';
  return nominal.inHours >= 48
      ? '${nominal.inDays}-day'
      : nominal.inHours >= 1
      ? '${nominal.inHours}-hour'
      : '${nominal.inMinutes}-minute';
}
