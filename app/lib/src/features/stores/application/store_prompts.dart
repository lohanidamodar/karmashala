import 'package:store_console/store_console.dart';

/// What an agent is handed for a review: the review as written, and where it
/// came from. The reply stays with the person; nothing here answers it.
String reviewPrompt(StoreApp app, StoreReview review) => [
  'A user review of ${app.name} (${app.bundleId}) on ${app.store.label}:',
  '',
  'Rating: ${review.rating} of 5',
  if (review.appVersion case final version?) 'App version: $version',
  if (review.locale case final locale?) 'Locale: $locale',
  'Written: ${review.createdAt.toUtc().toIso8601String()}',
  if (review.title case final title? when title.isNotEmpty) 'Title: $title',
  '',
  review.body,
  '',
  'Find what in this codebase the review is about. If it describes a bug, '
      'reproduce or locate it and propose a fix; if it is a request, say what '
      'it would take. Do not reply to the review.',
].join('\n');

/// What an agent is handed for a crash or ANR cluster.
String errorIssuePrompt(StoreApp app, StoreErrorIssue issue) => [
  'A ${issue.kind.label} cluster in ${app.name} (${app.bundleId}) on '
      '${app.store.label}, over the last 28 days:',
  '',
  if (issue.cause.isNotEmpty) 'Cause: ${issue.cause}',
  if (issue.location.isNotEmpty) 'Location: ${issue.location}',
  if (issue.reportCount case final count?) 'Reports: $count',
  if (issue.distinctUsers case final users?) 'Users affected: $users',
  if (_versions(issue) case final versions?) 'Version codes: $versions',
  if (issue.lastSeen case final at?)
    'Last seen: ${at.toUtc().toIso8601String()}',
  ?issue.consoleUrl,
  '',
  if (issue.sampleTrace case final trace?) ...[
    'A sample report'
        '${issue.sampleVersionCode == null ? '' : ' (version code ${issue.sampleVersionCode})'}:',
    '```',
    trace,
    '```',
  ] else
    'No sample stack trace could be read for this cluster.',
  '',
  'Find the cause in this codebase and propose a fix.',
].join('\n');

String? _versions(StoreErrorIssue issue) {
  final (first, last) = (issue.firstVersionCode, issue.lastVersionCode);
  if (first == null && last == null) return null;
  if (first == null || last == null || first == last) return first ?? last;
  return '$first to $last';
}
