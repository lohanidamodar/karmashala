import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../explorer/application/session_context.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../data/session_media_store.dart';
import '../domain/session_media_item.dart';

/// How often the media panel looks for new pictures.
///
/// Deliberately slower than the chat's two seconds. The chat is the
/// conversation and has to feel live; the panel is a place you go to find
/// something, and a picture appearing four seconds after it was pasted is not a
/// complaint anybody makes. It also only ticks while the panel is open — the
/// provider is `autoDispose`, so closing the panel stops it outright.
const Duration kSessionMediaPollInterval = Duration(seconds: 4);

/// How long to keep looking for a transcript the agent has not written yet.
const Duration kSessionMediaSearchInterval = Duration(seconds: 3);

/// How many times to ask the store locator before giving up.
///
/// Bounded, unlike the chat's search loop: the chat has nothing to show without
/// the file, whereas an empty media panel is a perfectly honest answer for a
/// session that has not written a transcript. Re-opening the panel tries again.
const int kSessionMediaSearchAttempts = 6;

/// Where extracted pictures and the per-transcript manifests live.
///
/// Under the application support directory rather than the temp directory: a
/// paste the panel is showing has to survive a reboot's temp sweep, or the
/// picture the user came back for is gone.
final sessionMediaCacheRootProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'media'));
  await root.create(recursive: true);
  return root;
});

/// Which session the media panel is describing.
///
/// The session **on screen**, not the one last clicked in the Explorer — the
/// same rule the rest of the side panel follows since Loop 85, because
/// switching terminal tabs changes which agent you are looking at and a panel
/// describing the other one is worse than useless. The Explorer's selection is
/// the fallback for a plain shell tab that runs no session of ours.
final mediaPanelSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(activePaneSessionIdProvider) ??
      ref.watch(selectedSessionIdProvider),
);

/// Where a session's record is, and how to read the paths inside it.
class SessionMediaSource {
  const SessionMediaSource({
    required this.cli,
    this.filePath,
    this.externalSessionId,
    this.environmentId,
  });

  /// The `AgentDescriptor.id` of the CLI that wrote the record — it decides
  /// which shape the scanner reads.
  final String cli;

  /// The record itself, when it is already known. An imported session carries
  /// its own path; a live one has to be located.
  final String? filePath;

  /// The CLI's own session id, used to locate [filePath] when it is null.
  final String? externalSessionId;

  /// The environment the agent runs in, so a path it wrote can be translated
  /// into one this process can open.
  final String? environmentId;
}

/// The record for [sessionId], native or imported.
final sessionMediaSourceProvider = Provider.autoDispose
    .family<SessionMediaSource?, String>((ref, sessionId) {
      // A launch rewrites the row; without this the panel would keep pointing
      // at the session's previous incarnation.
      ref.watch(sessionsRevisionProvider);

      final session = ref.read(sessionDaoProvider).getById(sessionId);
      if (session != null) {
        final installation = ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId);
        if (installation == null) return null;
        return SessionMediaSource(
          cli: installation.agentId,
          externalSessionId: session.externalSessionId,
          environmentId: installation.environmentId,
        );
      }

      // An imported CLI session names its own file, so there is nothing to
      // locate.
      final imported = ref.read(importedSessionDaoProvider).getById(sessionId);
      if (imported == null) return null;
      return SessionMediaSource(
        cli: imported.cli,
        filePath: imported.filePath,
        externalSessionId: imported.externalId,
        environmentId: imported.environmentId,
      );
    });

/// Translates a path the agent wrote into one this process can open, or null
/// when the session's environment is unknown.
///
/// The agent may be running in WSL while `dart:io` here is the Windows host, so
/// `/mnt/c/…/shot.png` has to become `C:\…\shot.png` before an image can be
/// drawn. Explicit, environment-aware, and the same call every other feature
/// makes — `EditorActions.windowsPathFor`.
final sessionMediaHostPathProvider = Provider.autoDispose
    .family<String? Function(String)?, String>((ref, sessionId) {
      final environmentId = ref
          .watch(sessionMediaSourceProvider(sessionId))
          ?.environmentId;
      if (environmentId == null) return null;
      final editor = ref.read(editorActionsProvider);
      return (path) => editor.windowsPathFor(
        EnvironmentPath(environmentId: environmentId, path: path),
      );
    });

/// Every picture [sessionId] has produced or been shown, newest first.
///
/// Polled, but cheaply: the scan resumes from where it stopped, so a tick over
/// an unchanged transcript costs one `stat()` and nothing else, and a tick over
/// a growing one reads only what was appended. Nothing here runs unless the
/// panel is open — `autoDispose` is the whole budget.
///
/// Never yields an error. A session with no readable record, a store we cannot
/// walk, a transcript the agent has not written yet: all of them are an empty
/// panel, which is the truth, and none of them is a reason to show a red box
/// where a list of pictures should be.
final sessionMediaProvider = StreamProvider.autoDispose
    .family<List<SessionMediaItem>, String>((ref, sessionId) async* {
      // No opening `yield []`: the panel would show its "nothing here yet"
      // state for the length of the first scan and then fill in, which reads as
      // a bug. It stays in `loading` until there is a real answer.
      final source = ref.watch(sessionMediaSourceProvider(sessionId));
      if (source == null) {
        yield const [];
        return;
      }

      final Directory root;
      try {
        root = await ref.watch(sessionMediaCacheRootProvider.future);
      } catch (_) {
        // No place to keep extracted pictures is no media panel; say nothing
        // rather than throwing at a side panel.
        yield const [];
        return;
      }
      final store = SessionMediaStore(root);

      var path = source.filePath;
      final externalId = source.externalSessionId;
      if (path == null && externalId != null && externalId.isNotEmpty) {
        final locator = ref.read(sessionTranscriptLocatorProvider);
        for (
          var attempt = 0;
          path == null && attempt < kSessionMediaSearchAttempts;
          attempt++
        ) {
          if (attempt > 0) {
            await Future<void>.delayed(kSessionMediaSearchInterval);
          }
          path = await locator.locate(
            agentId: source.cli,
            externalSessionId: externalId,
          );
        }
      }
      if (path == null) {
        yield const [];
        return;
      }

      final file = File(path);
      SessionMediaScan? scan;
      DateTime? lastModified;
      int? lastSize;
      var first = true;
      while (true) {
        DateTime? modified;
        int? size;
        try {
          // `stat()` rather than the synchronous pair: this runs on the UI
          // isolate and the transcript can live on a `\\wsl.localhost\…` share,
          // where the synchronous form measures 1.19 ms against 0.07 ms locally
          // (the measurement in `sessionChatTranscriptProvider`).
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.notFound) {
            modified = stat.modified;
            size = stat.size;
          }
        } catch (_) {
          modified = null;
          size = null;
        }
        // Some network shares and older filesystems expose coarse modification
        // times. An append can therefore change the transcript without moving
        // `modified`; size is the cheap second half of the file identity and
        // keeps new media from waiting for a later write to become visible.
        if (first || modified != lastModified || size != lastSize) {
          first = false;
          lastModified = modified;
          lastSize = size;
          try {
            scan = await store.refresh(path, source.cli, previous: scan);
            yield scan.newestFirst;
          } catch (_) {
            // A pass that failed leaves the last good list on screen rather
            // than emptying the panel under the user.
          }
        }
        await Future<void>.delayed(kSessionMediaPollInterval);
      }
    });
