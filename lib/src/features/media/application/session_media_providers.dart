import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

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
import '../../../core/paths/app_support_directory.dart';

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
  final support = await appSupportDirectory();
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

// -----------------------------------------------------------------------------
// Looking one picture up by the number the CLI printed
// -----------------------------------------------------------------------------

/// What a `[Image #6]` in a pane turned out to name.
///
/// Two answers and no third: a picture, or a sentence. There is deliberately no
/// "nothing happened" case — the owner's rule for this app is that anything it
/// cannot know for certain it says in words, and a Ctrl+click that silently did
/// nothing would be indistinguishable from a broken link.
sealed class SessionImageLookup {
  const SessionImageLookup();
}

/// The picture, ready to draw.
class SessionImageFound extends SessionImageLookup {
  const SessionImageFound(this.item, {this.matches = 1, this.resolveHostPath});

  final SessionMediaItem item;

  /// How many pictures in this session carry the same number — normally one.
  ///
  /// More than one means the CLI restarted and began counting again, which its
  /// own transcripts do: `…/popupbits/8a817d98-….jsonl` holds three runs, with
  /// `#1` starting each. Within a run the numbers are unique and strictly
  /// increasing, so [item] — the newest — is the one the process now printing
  /// into the pane means. A line further back in the scrollback, from an
  /// earlier run, would mean an older one, and nothing in the pane's text can
  /// tell the two apart. So the dialog says the number was reused rather than
  /// presenting a guess as a fact.
  final int matches;

  /// Translates a path the *agent* wrote into one this process can open, or
  /// null when there is nothing to translate. Carried rather than applied, so
  /// the viewer gets it on exactly the terms the media panel already uses.
  final String? Function(String path)? resolveHostPath;
}

/// Why there is no picture, in a sentence meant to be shown to the user.
class SessionImageUnavailable extends SessionImageLookup {
  const SessionImageUnavailable(this.reason);

  final String reason;
}

/// Finds the picture [pasteId] names inside [sessionId].
typedef SessionImageLookupFn =
    Future<SessionImageLookup> Function(String sessionId, int pasteId);

/// The lookup behind Ctrl+clicking a `[Image #6]` in a terminal pane.
///
/// **On demand, never on a poll.** Unlike [sessionMediaProvider] this runs once,
/// when somebody clicks. It goes through the same [SessionMediaStore], so a
/// session whose panel has been open resumes from the manifest and costs a
/// `stat()`; a session whose panel has never been opened pays one full scan,
/// which is the panel's own first-open cost and is what makes the reference
/// clickable without the user having to open the panel first.
///
/// **The newest match wins, and says when it was not the only one.** The number
/// is a CLI *process*'s counter: within one run it is unique and climbs, and it
/// restarts when the process does. `…/popupbits/8a817d98-….jsonl` is three runs
/// — `#1..#1`, `#1..#7`, `#1..#6` — thirteen pastes wearing seven numbers. The
/// text a pane is printing now came from the process running now, so the newest
/// match is the right answer for it; a line scrolled back from an earlier run
/// means an older picture and the pane's text cannot tell which. [matches] is
/// therefore carried out, and the dialog says the number was reused instead of
/// quietly presenting a guess.
final sessionImageLookupProvider = Provider<SessionImageLookupFn>(
  (ref) => (sessionId, pasteId) async {
    final label = '[Image #$pasteId]';
    final source = ref.read(sessionMediaSourceProvider(sessionId));
    if (source == null) {
      return SessionImageUnavailable(
        'Karmashala has no record of this pane\'s session, so it cannot look '
        '$label up.',
      );
    }

    final Directory root;
    try {
      root = await ref.read(sessionMediaCacheRootProvider.future);
    } catch (_) {
      return SessionImageUnavailable(
        'Karmashala has nowhere to keep extracted pictures, so it cannot open '
        '$label.',
      );
    }

    var path = source.filePath;
    final externalId = source.externalSessionId;
    if (path == null && externalId != null && externalId.isNotEmpty) {
      // One attempt, not the panel's retry loop: a click is a question asked
      // once, and "not written yet" is an answer worth giving straight away.
      path = await ref
          .read(sessionTranscriptLocatorProvider)
          .locate(agentId: source.cli, externalSessionId: externalId);
    }
    if (path == null) {
      return SessionImageUnavailable(
        'Karmashala has not found this session\'s transcript yet, so it cannot '
        'open $label.',
      );
    }

    final SessionMediaScan scan;
    try {
      scan = await SessionMediaStore(root).refresh(path, source.cli);
    } catch (_) {
      return SessionImageUnavailable(
        'Karmashala could not read this session\'s transcript, so it cannot '
        'open $label.',
      );
    }

    SessionMediaItem? match;
    var matches = 0;
    for (final item in scan.items) {
      if (item.pasteId != pasteId) continue;
      match = item;
      matches++;
    }
    if (match == null) {
      return SessionImageUnavailable(
        '$label is not among this session\'s images. Karmashala reads them '
        'from the transcript, so a picture that has not been sent yet — or one '
        'from a conversation this pane resumed — is not in it.',
      );
    }
    if (match.path == null) {
      return SessionImageUnavailable(
        match.problem ?? 'There is no picture on disk for $label.',
      );
    }
    return SessionImageFound(
      match,
      matches: matches,
      resolveHostPath: match.fromAgentEnvironment
          ? ref.read(sessionMediaHostPathProvider(sessionId))
          : null,
    );
  },
);
