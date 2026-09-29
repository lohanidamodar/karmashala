import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../agents/application/agent_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import 'package:agent_cli/process.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:agent_cli/read.dart'
    show SessionMediaItem, SessionMediaScan, SessionMediaStore;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefusalCode, DataRefused, SessionMediaRead;
import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/paths/app_support_directory.dart';
import '../../../core/server/remote_server_access.dart';
import '../../files/data/files_client.dart';
import '../../terminal/application/local_host_providers.dart'
    show serverAccessProvider;
import '../data/server_media_files.dart';

/// How often the media panel looks for new pictures — slower than the chat's
/// two seconds on purpose, and only while the panel is open (`autoDispose`).
const Duration kSessionMediaPollInterval = Duration(seconds: 4);

/// How long to keep looking for a transcript the agent has not written yet.
const Duration kSessionMediaSearchInterval = Duration(seconds: 3);

/// How many times to ask the store locator before giving up. Bounded, unlike
/// the chat's search loop: an empty media panel is an honest answer.
const int kSessionMediaSearchAttempts = 6;

/// Where extracted pictures and the per-transcript manifests live —
/// application support, not temp, so a paste survives a reboot's temp sweep.
final sessionMediaCacheRootProvider = FutureProvider<Directory>((ref) async {
  final support = await appSupportDirectory();
  final root = Directory(p.join(support.path, 'media'));
  await root.create(recursive: true);
  return root;
});

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

      final session = ref.read(sessionsDataProvider).getById(sessionId);
      if (session != null) {
        final installation = ref
            .read(agentInstallationsDataProvider)
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
      final imported = ref.read(importedSessionsProvider).getById(sessionId);
      if (imported == null) return null;
      return SessionMediaSource(
        cli: imported.cli,
        filePath: imported.filePath,
        externalSessionId: imported.externalId,
        environmentId: imported.environmentId,
      );
    });

/// Translates a path the agent wrote into one this process can open — the agent
/// may be in WSL — or null when the session's environment is unknown.
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

/// Pictures brought from a server elsewhere, kept per server beside its
/// layout (`machines/<hostId>/media`).
final serverMediaFilesProvider = Provider<ServerMediaFiles>((ref) {
  final access = ref.watch(serverAccessProvider);
  final hostId = access is RemoteServerAccess ? access.hostId : 'local';
  return ServerMediaFiles(ref.watch(filesClientProvider), () async {
    final support = await appSupportDirectory();
    final folder = Directory(p.join(support.path, 'machines', hostId, 'media'));
    await folder.create(recursive: true);
    return folder;
  });
});

/// How a picture an agent of [sessionId] names is brought here, or null when
/// this disk has it (`readsServerDisk`), so a chat reads it as before.
final sessionImageFetchProvider = Provider.autoDispose
    .family<Future<File> Function(String path)?, String>((ref, sessionId) {
      // Selected, not watched whole: a chat view watches this, and the
      // source moves with every session's revision.
      if (ref.watch(capabilitiesProvider.select((c) => c.readsServerDisk))) {
        return null;
      }
      final environmentId = ref.watch(
        sessionMediaSourceProvider(sessionId).select((s) => s?.environmentId),
      );
      if (environmentId == null) return null;
      final files = ref.watch(serverMediaFilesProvider);
      return (path) => files.fetch(
        EnvironmentPath(environmentId: environmentId, path: path),
      );
    });

/// How an item the server listed for [sessionId] is brought here, or null
/// when its paths open on this disk as they are.
final sessionMediaFetchProvider = Provider.autoDispose
    .family<Future<File> Function(SessionMediaItem item)?, String>((
      ref,
      sessionId,
    ) {
      final caps = ref.watch(capabilitiesProvider);
      if (caps.readsServerDisk || !caps.mediaViaServer) return null;
      final agentEnvironment = ref.watch(
        sessionMediaSourceProvider(sessionId).select((s) => s?.environmentId),
      );
      final files = ref.watch(serverMediaFilesProvider);
      return (item) async {
        final path = item.path;
        if (path == null) {
          throw MediaUnavailable(item.problem ?? 'No preview.');
        }
        // The server's own copies are on its host; a file the agent read is
        // spelled in the agent's environment.
        return files.fetch(
          EnvironmentPath(
            environmentId: item.fromAgentEnvironment
                ? agentEnvironment ?? localHostEnvironmentId
                : localHostEnvironmentId,
            path: path,
          ),
        );
      };
    });

/// Every picture [sessionId] has, newest first. An unchanged transcript costs a
/// `stat()`, and no readable record is an empty panel, not a red box.
final sessionMediaProvider = StreamProvider.autoDispose
    .family<List<SessionMediaItem>, String>((ref, sessionId) async* {
      // No opening `yield []`: the "nothing here yet" state followed by a fill
      // reads as a bug, so it stays in `loading` until there is a real answer.
      final source = ref.watch(sessionMediaSourceProvider(sessionId));
      if (source == null) {
        yield const [];
        return;
      }

      // Listed by the server, where the record is (Stage 0 step 10), on this
      // machine too; an older server refuses the kind and this disk is read.
      if (ref.watch(capabilitiesProvider.select((c) => c.mediaViaServer))) {
        final data = ref.read(dataClientProvider);
        var disposed = false;
        ref.onDispose(() => disposed = true);
        String? known;
        var answered = false;
        var older = false;
        while (!disposed && !older) {
          try {
            final listing = (await data.send(
              SessionMediaRead(sessionId, known: known),
            )).value;
            if (!listing.unchanged) {
              known = listing.stamp;
              answered = true;
              yield listing.items;
            }
          } on DataRefused catch (refusal) {
            older = refusal.code == DataRefusalCode.invalid;
          } catch (_) {
            // A dropped link: what is on screen stays; the next poll asks.
          }
          if (older) break;
          if (!answered) {
            answered = true;
            yield const [];
          }
          await Future<void>.delayed(kSessionMediaPollInterval);
        }
        if (!older) return;
      }

      final Directory root;
      try {
        root = await ref.read(sessionMediaCacheRootProvider.future);
      } catch (_) {
        // Nowhere to keep pictures is no panel; say nothing rather than throw.
        yield const [];
        return;
      }
      final store = SessionMediaStore(
        root,
        registry: ref.read(agentRegistryProvider),
      );

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
          // `stat()`, not the synchronous pair: on a `\\wsl.localhost\…` share
          // that measures 1.19 ms against 0.07 ms locally, on the UI isolate.
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.notFound) {
            modified = stat.modified;
            size = stat.size;
          }
        } catch (_) {
          modified = null;
          size = null;
        }
        // Coarse modification times exist, so an append can leave `modified`
        // untouched; size is the cheap other half of the file identity.
        if (first || modified != lastModified || size != lastSize) {
          first = false;
          lastModified = modified;
          lastSize = size;
          try {
            scan = await store.refresh(path, source.cli, previous: scan);
            yield scan.newestFirst;
          } catch (_) {
            // A failed pass leaves the last good list on screen.
          }
        }
        await Future<void>.delayed(kSessionMediaPollInterval);
      }
    });

/// What a `[Image #6]` in a pane turned out to name: a picture, or a sentence
/// saying why not. There is deliberately no silent "nothing happened" case.
sealed class SessionImageLookup {
  const SessionImageLookup();
}

class SessionImageFound extends SessionImageLookup {
  const SessionImageFound(
    this.item, {
    this.matches = 1,
    this.resolveHostPath,
    this.fetch,
  });

  final SessionMediaItem item;

  /// How many pictures carry this number — above one the CLI restarted its
  /// counter, and the dialog says so rather than presenting a guess.
  final int matches;

  /// Translates a path the *agent* wrote into one this process can open, or
  /// null when there is nothing to translate. Carried rather than applied.
  final String? Function(String path)? resolveHostPath;

  /// Brings the picture from a server elsewhere; null when this disk has it.
  final Future<File> Function(String path)? fetch;
}

/// Why there is no picture, in a sentence meant to be shown to the user.
class SessionImageUnavailable extends SessionImageLookup {
  const SessionImageUnavailable(this.reason);

  final String reason;
}

typedef SessionImageLookupFn =
    Future<SessionImageLookup> Function(String sessionId, int pasteId);

/// The lookup behind Ctrl+clicking a `[Image #6]`, through the same
/// [SessionMediaStore]; the newest wins, and [SessionImageFound.matches] warns.
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

    // Oldest first, as a scan holds them.
    List<SessionMediaItem>? items;
    if (ref.read(capabilitiesProvider).mediaViaServer) {
      try {
        final listing =
            (await ref
                    .read(dataClientProvider)
                    .send(SessionMediaRead(sessionId)))
                .value;
        items = listing.items.reversed.toList(growable: false);
      } on DataRefused catch (refusal) {
        // `invalid` is a server older than the feature: read this disk.
        if (refusal.code != DataRefusalCode.invalid) {
          return SessionImageUnavailable(
            'The server could not list this session\'s images, so Karmashala '
            'cannot open $label: ${refusal.message}',
          );
        }
      } catch (_) {
        return SessionImageUnavailable(
          'Karmashala could not reach the server, so it cannot open $label.',
        );
      }
    }

    if (items == null) {
      final Directory root;
      try {
        root = await ref.read(sessionMediaCacheRootProvider.future);
      } catch (_) {
        return SessionImageUnavailable(
          'Karmashala has nowhere to keep extracted pictures, so it cannot '
          'open $label.',
        );
      }

      var path = source.filePath;
      final externalId = source.externalSessionId;
      if (path == null && externalId != null && externalId.isNotEmpty) {
        // One attempt, not the panel's retry loop: a click asks once, and
        // "not written yet" is an answer worth giving straight away.
        path = await ref
            .read(sessionTranscriptLocatorProvider)
            .locate(agentId: source.cli, externalSessionId: externalId);
      }
      if (path == null) {
        return SessionImageUnavailable(
          'Karmashala has not found this session\'s transcript yet, so it '
          'cannot open $label.',
        );
      }

      final SessionMediaScan scan;
      try {
        scan = await SessionMediaStore(
          root,
          registry: ref.read(agentRegistryProvider),
        ).refresh(path, source.cli);
      } catch (_) {
        return SessionImageUnavailable(
          'Karmashala could not read this session\'s transcript, so it cannot '
          'open $label.',
        );
      }
      items = scan.items;
    }

    SessionMediaItem? match;
    var matches = 0;
    for (final item in items) {
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
    final fetch = ref.read(sessionMediaFetchProvider(sessionId));
    final found = match;
    return SessionImageFound(
      match,
      matches: matches,
      resolveHostPath: match.fromAgentEnvironment
          ? ref.read(sessionMediaHostPathProvider(sessionId))
          : null,
      fetch: fetch == null ? null : (_) => fetch(found),
    );
  },
);
