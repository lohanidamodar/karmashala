import 'package:flutter/material.dart';

import '../../server/application/server_files.dart' show describeBytes;
import '../application/backup_client.dart';

/// [at] as a date and time in this machine's zone: "9 Oct 2026, 15:30".
String describeBackupTime(BuildContext context, DateTime? at) {
  if (at == null) return 'an unknown time';
  final local = at.toLocal();
  final words = MaterialLocalizations.of(context);
  return '${words.formatMediumDate(local)}, '
      '${words.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}

/// What a backup holds, one fact a line.
List<String> describeBackupContents(BackupSummary summary) {
  String plural(int n, String one, [String? many]) =>
      '$n ${n == 1 ? one : (many ?? '${one}s')}';
  return [
    '${plural(summary.count('sessions'), 'session')}, '
        '${plural(summary.count('projects'), 'project')}, '
        '${plural(summary.count('session_artifacts'), 'artifact')} and '
        '${plural(summary.count('verification_runs'), 'verification run')}',
    '${plural(summary.fileCount, 'file')} '
        '(${describeBytes(summary.fileBytes)}): attachments, uploads, '
        'artifacts, evidence, screenshots and recordings',
    if (summary.checkpointRefs > 0)
      '${plural(summary.checkpointRefs, 'checkpoint ref')} in '
          '${plural(summary.repositories, 'repository', 'repositories')}: '
          'the repositories must still hold them',
    if (summary.skipped > 0)
      '${plural(summary.skipped, 'file')} left out because '
          '${summary.skipped == 1 ? 'it looks' : 'they look'} like a secret',
  ];
}
