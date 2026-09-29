import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:path/path.dart' as p;

import '../application/session_export.dart';
import '../application/session_notice.dart';

/// Writes a session's archive somewhere the user chose, and says where it went.
///
/// A folder rather than a save dialog: the app already has one way of asking
/// for a place on any of its machines, and an export that could only be saved
/// through the system dialog would be the second.
Future<void> exportSession(
  BuildContext context,
  WidgetRef ref,
  String sessionId, {
  @visibleForTesting Future<String?> Function()? chooseFolder,
  @visibleForTesting
  Future<void> Function(String path, List<ZipEntry> entries)? write,
}) async {
  final SessionExport export;
  // A long record read from its server comes a page at a time: say so while
  // more are coming, and take it down once the export is built.
  var reading = false;
  void progress(int read, int total) {
    if (read >= total || read >= kExportTurnLimit) return;
    reading = true;
    _say(
      ref,
      sessionId,
      'Reading the conversation from its server: $read of $total turns…',
    );
  }

  try {
    export = await ref
        .read(sessionExporterProvider)
        .build(sessionId, progress: progress);
  } on Object catch (error) {
    _say(ref, sessionId, 'The export could not be built: $error', bad: true);
    return;
  }
  if (reading) ref.read(sessionNoticesProvider.notifier).dismiss(sessionId);
  if (!context.mounted) return;

  final folder =
      await (chooseFolder?.call() ??
          // This device's folders, whatever server the window uses: the zip
          // is written here, below.
          pickDeviceDirectory(
            what: 'Where to save the export',
            context: context,
            // Nothing here knows a folder on this computer worth suggesting —
            // an archive is for somewhere personal, not for the checkout this
            // session ran in. The fallback chain picks one that exists rather
            // than letting the shell restore its own last folder.
            startNear: null,
            confirmButtonText: 'Export here',
          ));
  if (folder == null) return;

  final path = p.join(folder, export.fileName);
  try {
    await (write?.call(path, export.entries) ??
        writeZipArchive(path, export.entries).then((_) {}));
  } on Object catch (error) {
    _say(ref, sessionId, 'The export could not be written: $error', bad: true);
    return;
  }
  // The gaps are named here too, not only inside the archive: somebody who
  // attaches this to a bug report should know before they send it that the
  // conversation is missing.
  final refusal = export.transcriptRefusal;
  _say(
    ref,
    sessionId,
    [
      'Exported to $path.',
      if (refusal != null)
        'It has no transcript — $refusal. Everything else is in it.'
      else if (export.omittedTurns > 0)
        'It holds the last ${export.turns} turns; ${export.omittedTurns} '
            'earlier ones were over the export budget.',
    ].join(' '),
    bad: refusal != null,
  );
}

void _say(
  WidgetRef ref,
  String sessionId,
  String message, {
  bool bad = false,
}) => ref
    .read(sessionNoticesProvider.notifier)
    .post(
      sessionId,
      SessionNotice(
        message: message,
        tone: bad ? SessionNoticeTone.warning : SessionNoticeTone.neutral,
      ),
    );
