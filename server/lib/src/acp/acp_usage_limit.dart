import 'dart:convert';

import 'package:karmashala_acp/karmashala_acp.dart' show AcpRpcError;

/// The failure reason an ACP turn carries when the agent refused it on a
/// usage or rate limit. ACP has no error code for it, so it is read from the
/// error's words ([isUsageLimitError]).
const String kProtocolUsageLimitReason = 'usage_limit';

/// The furthest ahead a reset read out of an error's words is believed.
const Duration kProtocolResetHorizon = Duration(days: 8);

final RegExp _limitWords = RegExp(
  r'usage[ _-]?limit|rate[ _-]?limit|limit reached|hit your( \w+)? limit|quota'
  r'|resource[ _]exhausted|too many requests',
  caseSensitive: false,
);

final RegExp _usageWords = RegExp(
  r'usage[ _-]?limit|limit reached|hit your( \w+)? limit|quota'
  r'|resource[ _]exhausted',
  caseSensitive: false,
);

/// A bare rate limit is a usage limit only when its reset is at least this
/// far off; a shorter wait is a passing throttle.
const Duration kProtocolLimitMinimumWait = Duration(minutes: 5);

/// Whether [words] speak of a spent usage allowance or quota, not just a
/// request rate.
bool hasUsageLimitWording(Iterable<String> words) =>
    _usageWords.hasMatch(words.join('\n'));

/// Whether [error] is an agent refusing a turn on a usage or rate limit, by
/// its message or data — never by which agent said it.
bool isUsageLimitError(AcpRpcError error) =>
    _limitWords.hasMatch(usageLimitWords(error).join('\n'));

/// What [error] said, verbatim: the message, then its data as JSON.
List<String> usageLimitWords(AcpRpcError error) => [
  error.message,
  if (error.data case final data?) data is String ? data : _json(data),
];

String _json(Object data) {
  try {
    return jsonEncode(data);
  } on Object {
    return '$data';
  }
}

final RegExp _epoch = RegExp(r'(?<![\d.])(\d{10})(?![\d.])');
final RegExp _iso = RegExp(
  r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})',
);
final RegExp _relative = RegExp(
  r'\b(?:in|after)\s+((?:\d+(?:\.\d+)?\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b[\s,]*(?:and\s+)?)+)',
  caseSensitive: false,
);
final RegExp _part = RegExp(
  r'(\d+(?:\.\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b',
  caseSensitive: false,
);

/// When the limit in [words] resets, if they say so in a form with no time
/// zone to guess: epoch seconds, an ISO time with its offset, or "in 2h 5m".
/// A wall-clock time ("resets 3pm") is not read. Null when none is in the
/// future and within [kProtocolResetHorizon] of [now].
DateTime? usageLimitResetIn(Iterable<String> words, DateTime now) {
  final text = words.join('\n');
  bool plausible(DateTime at) =>
      at.isAfter(now) && !at.isAfter(now.add(kProtocolResetHorizon));
  for (final match in _epoch.allMatches(text)) {
    final at = DateTime.fromMillisecondsSinceEpoch(
      int.parse(match.group(1)!) * 1000,
      isUtc: true,
    );
    if (plausible(at)) return at;
  }
  for (final match in _iso.allMatches(text)) {
    final at = DateTime.tryParse(match.group(0)!.replaceFirst(' ', 'T'));
    if (at != null && plausible(at.toUtc())) return at.toUtc();
  }
  for (final match in _relative.allMatches(text)) {
    var seconds = 0.0;
    for (final part in _part.allMatches(match.group(1)!)) {
      final amount = double.parse(part.group(1)!);
      seconds +=
          amount *
          switch (part.group(2)!.toLowerCase()[0]) {
            'd' => 86400,
            'h' => 3600,
            'm' => 60,
            _ => 1,
          };
    }
    final at = now.add(Duration(milliseconds: (seconds * 1000).round()));
    if (plausible(at)) return at.toUtc();
  }
  return null;
}
