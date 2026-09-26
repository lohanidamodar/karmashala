/// Quitting while agents are mid-turn, and picking them back up next launch.
///
/// Karmashala kills every PTY it hosts when it goes. Until now it did that
/// silently: the window closed and whatever three agents were halfway through
/// simply stopped, with no list of what had just been interrupted and no way
/// to ask for them back. This is the list, the question, and the intent — and
/// the honest part, which is that **the intent is the only thing recorded**.
/// Nothing here promises a turn will be finished; it promises the sessions will
/// be open again, which is what Karmashala can actually deliver.
library;

import 'dart:convert';

import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/instances.dart'
    show HostedTerminalInstance;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_status_providers.dart';

/// Where the intent is kept. Metadata, not a table: it is one list that is
/// written at most once per quit and consumed on the next launch, and a table
/// would outlive the thing it describes.
const String kQuitResumeKey = 'quit_resume_intent';

/// How stale an intent may be and still be acted on. A machine booted a week
/// later is not the session the user walked away from, and reopening five
/// agents unasked at that distance is a surprise, not a convenience.
const Duration kQuitResumeFreshness = Duration(hours: 12);

/// Whether Karmashala is hosting a live pane for a session right now.
///
/// A provider rather than a direct call, in the shape [sessionStatusLookupProvider]
/// already has: the launcher answers this from a terminal controller, and both
/// the quit question and the launch pass need to be askable without one.
final sessionIsHostedLiveProvider = Provider<bool Function(String)>(
  (ref) =>
      (sessionId) =>
          ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null,
);

/// The pane running [String] session when that session lives outside the app
/// — in a session host, or under tmux over SSH — so a quit disconnects from it
/// and it keeps running; or null.
final sessionHostedPaneProvider =
    Provider<HostedTerminalInstance? Function(String)>(
      (ref) => (sessionId) {
        final paneId = ref.read(sessionsDataProvider).getById(sessionId)?.paneId;
        if (paneId == null) return null;
        final instance = ref
            .read(terminalSessionsControllerProvider.notifier)
            .instanceFor(paneId);
        return switch (instance) {
          final HostedTerminalInstance hosted when hosted.outlivesApp => hosted,
          _ => null,
        };
      },
    );

/// One session running when the app quits.
class InterruptedSession {
  const InterruptedSession({
    required this.id,
    required this.title,
    required this.agentName,
    required this.working,
    this.keptBy,
  });

  final String id;
  final String title;
  final String agentName;

  /// Whether the agent was mid-turn, as opposed to open and idle. Both are
  /// interrupted; only one loses work in progress, and the list says which.
  final bool working;

  /// Where it keeps running after a quit unless it is ended — "the session
  /// host", "tmux on build-box" — or null when a quit stops it.
  final String? keptBy;

  bool get keepsRunning => keptBy != null;

  String get line => '$title — $agentName${working ? ', mid-turn' : ''}';
}

/// Why a recorded intent was not acted on, or null when it was.
///
/// Spelled out as sentences because every one of them is a case where the user
/// asked for something and did not get it, and a silent skip would read as the
/// feature not working.
typedef ResumeSkip = ({String sessionId, String reason});

/// What one launch found waiting for it.
class QuitResumePlan {
  const QuitResumePlan({this.resume = const [], this.skipped = const []});

  /// Session ids to reopen, in the order they were recorded.
  final List<String> resume;
  final List<ResumeSkip> skipped;

  bool get isEmpty => resume.isEmpty && skipped.isEmpty;
}

/// Reads what is live, records what to come back to, and decides on launch
/// which of it still makes sense.
class QuitResumeService {
  QuitResumeService(this._ref);

  final Ref _ref;
  static final _log = AppLogger.named('sessions.quit');

  /// Ends the host sessions among [sessionIds] for good, for a quit that was
  /// asked not to leave them running. Bounded: a host that will not answer
  /// must not hold the quit open.
  Future<void> endHosted(Iterable<String> sessionIds) async {
    final hosted = _ref.read(sessionHostedPaneProvider);
    await Future.wait([
      for (final id in sessionIds)
        if (hosted(id) case final pane?)
          pane.endHostedSession().timeout(
            const Duration(seconds: 5),
            onTimeout: () => _log.warning('the host did not end $id in time'),
          ),
    ]);
  }

  /// The sessions a quit right now would stop, newest first. Only sessions
  /// **this app is hosting**: one we merely have a row for is not running.
  List<InterruptedSession> interrupted() {
    final isLive = _ref.read(sessionIsHostedLiveProvider);
    final hosted = _ref.read(sessionHostedPaneProvider);
    final status = _ref.read(sessionStatusLookupProvider);
    final installations = _ref.read(agentInstallationDaoProvider);
    final registry = _ref.read(agentRegistryProvider);

    final live = <InterruptedSession>[];
    for (final session in _ref.read(sessionsDataProvider).getClaimingLive()) {
      if (!isLive(session.id)) continue;
      final agentId = installations
          .getById(session.agentInstallationId)
          ?.agentId;
      live.add(
        InterruptedSession(
          id: session.id,
          title: session.title,
          agentName: agentId == null
              ? 'an agent that is no longer installed'
              : registry.displayNameFor(agentId),
          working: status(session.id)?.status == AgentActivityStatus.working,
          keptBy: hosted(session.id)?.keptBy,
        ),
      );
    }
    // Mid-turn first: those are the ones the question is really about.
    live.sort((a, b) {
      if (a.working != b.working) return a.working ? -1 : 1;
      return a.title.compareTo(b.title);
    });
    return live;
  }

  /// Records that [sessionIds] should be reopened next launch.
  ///
  /// Returns false when it could not be written. **The caller must say so**:
  /// the fallback is a plain interruption, and a user who ticked the box and
  /// was told nothing would reasonably assume their work was coming back.
  bool remember(List<String> sessionIds) {
    if (sessionIds.isEmpty) return true;
    try {
      _ref
          .read(appPreferencesProvider)
          .write(
            kQuitResumeKey,
            jsonEncode({
              'at': _ref.read(clockProvider).nowUtc().toIso8601String(),
              'sessions': sessionIds,
            }),
          );
      _log.info('quit: will reopen ${sessionIds.length} session(s) next time.');
      return true;
    } on Object catch (error, stack) {
      _log.warning('quit: could not record the resume intent.', error, stack);
      return false;
    }
  }

  /// Clears any recorded intent — what "Quit" without the box ticked means, so
  /// last time's answer cannot be applied to this time's quit.
  void forget() {
    try {
      _ref.read(appPreferencesProvider).write(kQuitResumeKey, '');
    } on Object catch (error) {
      _log.warning('quit: could not clear the resume intent: $error');
    }
  }

  /// What to reopen on this launch, and what was dropped and why. Consuming
  /// the intent is part of reading it: an intent acted on twice would reopen
  /// sessions the user closed in between.
  QuitResumePlan planForLaunch() {
    final raw = _ref.read(appPreferencesProvider).read(kQuitResumeKey);
    if (raw == null || raw.isEmpty) return const QuitResumePlan();
    forget();

    final List<String> ids;
    final DateTime? at;
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      ids = [
        for (final id in (decoded['sessions'] as List?) ?? const [])
          if (id is String) id,
      ];
      at = DateTime.tryParse((decoded['at'] as String?) ?? '');
    } on Object catch (error) {
      _log.warning('quit: the recorded resume intent was unreadable: $error');
      return const QuitResumePlan();
    }
    if (ids.isEmpty) return const QuitResumePlan();

    final now = _ref.read(clockProvider).nowUtc();
    if (at == null || now.difference(at) > kQuitResumeFreshness) {
      _log.info('quit: the recorded resume intent was too old to act on.');
      return QuitResumePlan(
        skipped: [
          for (final id in ids)
            (
              sessionId: id,
              reason:
                  'it was recorded ${at == null ? 'at an unreadable time' : 'more than '
                            '${kQuitResumeFreshness.inHours} hours ago'}, which is '
                  'too long ago to reopen it unasked',
            ),
        ],
      );
    }

    final dao = _ref.read(sessionsDataProvider);
    final isLive = _ref.read(sessionIsHostedLiveProvider);
    final resume = <String>[];
    final skipped = <ResumeSkip>[];
    for (final id in ids) {
      final skip = _refusal(dao.getById(id), id, isLive);
      if (skip == null) {
        resume.add(id);
      } else {
        skipped.add((sessionId: id, reason: skip));
      }
    }
    _log.info(
      'quit: reopening ${resume.length} of ${ids.length} recorded session(s); '
      '${skipped.length} skipped.',
    );
    return QuitResumePlan(resume: resume, skipped: skipped);
  }

  /// Why [session] is not reopened, or null. Guarded rather than unconditional:
  /// the user asked for the sessions they had, not for whatever those rows
  /// became while the app was shut.
  String? _refusal(Session? session, String id, bool Function(String) isLive) {
    if (session == null) return 'it is no longer in the workspace';
    if (session.isArchived) return 'it was archived';
    if (isLive(id)) return 'it is already open';
    final externalId = session.externalSessionId;
    if (externalId == null || externalId.isEmpty) {
      return 'it recorded no conversation to resume';
    }
    return null;
  }
}

final quitResumeServiceProvider = Provider<QuitResumeService>(
  QuitResumeService.new,
);
