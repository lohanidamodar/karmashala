// Copied verbatim from lib/src/features/sessions/domain/session_resume.dart; see PACKAGE_SPLIT.md on consolidation.
/// A coarse, deliberately unexciting rendering of an age.
///
/// Rounded down and capped at days, because the point of the number is to tell
/// the user how much to trust the claim beside it, not to be a clock. "just now"
/// covers the first minute rather than counting seconds, which would make a
/// static row look live.
String describeAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}
