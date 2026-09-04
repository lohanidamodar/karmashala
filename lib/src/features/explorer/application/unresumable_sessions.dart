import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../cli_detection/application/conversation_presence_sweep.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/unkept_promise.dart';
import 'bulk_session_delete.dart';

/// One row of the review, with the verdict that was actually reached for it.
class UnresumableSession {
  const UnresumableSession({
    required this.session,
    required this.agentName,
    required this.verdict,
  });

  final Session session;

  /// Whose store was asked. Named on the row because the answer belongs to a
  /// CLI, not to Karmashala.
  final String agentName;

  final PromiseVerdict verdict;

  String get note => promiseVerdictNote(verdict, agentName);
}

/// What one reading found.
///
/// [removable] and [uncertain] are separate lists rather than one list with a
/// flag, because only one of them is ever acted on and the separation is what
/// makes that impossible to get wrong at the call site.
class UnresumableReview {
  const UnresumableReview({
    required this.removable,
    required this.uncertain,
    required this.storesRead,
    required this.storesUnreadable,
    this.checkedAt,
  });

  const UnresumableReview.unchecked()
    : removable = const [],
      uncertain = const [],
      storesRead = 0,
      storesUnreadable = 0,
      checkedAt = null;

  /// Rows whose agent store was read to the end without the conversation in it
  /// — [PromiseVerdict.unkept], and the only rows [SessionBulkDelete] is ever
  /// handed from here.
  final List<UnresumableSession> removable;

  /// Rows we could not judge. Shown, counted, and never deleted.
  final List<UnresumableSession> uncertain;

  final int storesRead;
  final int storesUnreadable;

  /// When the stores were read, or null before the first reading. Rendered as
  /// an age, never as a bare "now".
  final DateTime? checkedAt;

  bool get hasRun => checkedAt != null;

  bool get isEmpty => removable.isEmpty && uncertain.isEmpty;

  String get summary => unkeptPromiseSummary(
    removable: removable.length,
    uncertain: uncertain.length,
    storesRead: storesRead,
  );
}

/// Finds the rows that name a conversation their agent does not have, and acts
/// on them.
///
/// **The state this exists for already has words**, in
/// `resumeMissingConversationMessage`: a session whose agent takes a
/// `--session-id` gets one of our ids at launch and records it immediately,
/// which makes the id a promise about a conversation that does not exist yet. A
/// launch that failed, or a session nothing was ever said in, leaves the promise
/// unkept. Until now that was only ever discovered *reactively*, by resuming the
/// row and reading the explanation.
///
/// ## Two passes, and why
///
/// **The cheap signal does not work.** `externalSessionId == null` cannot find
/// these rows, because the id is recorded at launch — a dead row and a live row
/// are identical on that field. Knowing for certain means asking the CLI whether
/// it has the conversation, and doing that per row, eagerly, is exactly the cost
/// the Explorer's per-row git probes were just relieved of. So:
///
/// 1. **Screening** — [screenSessionPromise], per row, from the row and two
///    in-memory facts. No disk, no subprocess, no store. This is what stays
///    flat as the workspace grows.
/// 2. **One sweep** — [conversationPresenceSweepProvider], a single pass over
///    every located store, run only when the user asks. Its cost is
///    O(stores), not O(rows), and it answers for every candidate at once.
///
/// The alternative — the existing single-row `conversationPresenceProvider`,
/// per candidate — was rejected on cost: Codex's answer walks its whole
/// `sessions/` tree, so forty candidates would be forty walks of it. The sweep
/// keeps the *same rule* as that probe, so the two cannot disagree about
/// whether a resume would have been refused.
///
/// ## Why nothing is cached and nothing is scheduled
///
/// There was a hope that the app's existing store sweeps had already paid for
/// this. They have not: nothing memoizes `SessionTranscriptLocator.index()`,
/// `SessionStatusRegistry` keeps only a per-session path once found (and only
/// for sessions whose agent has a state file *and* still wants a probe), and
/// `SessionAutoImportService` runs on a user action. There is no existing
/// artefact to cross-check against, so this reads the stores itself — once,
/// when asked, never on a timer. §19's third rule.
class UnresumableSessionsController extends Notifier<UnresumableReview> {
  @override
  UnresumableReview build() => const UnresumableReview.unchecked();

  bool _running = false;

  bool get running => _running;

  /// Screens every row, then reads the stores once, then labels what survived.
  Future<void> refresh() async {
    if (_running) return;
    _running = true;
    try {
      final candidates = _screen();
      // No candidate means no store needs reading at all — the honest zero, and
      // it costs nothing to reach.
      if (candidates.isEmpty) {
        final now = ref.read(clockProvider).nowUtc();
        state = UnresumableReview(
          removable: const [],
          uncertain: const [],
          storesRead: 0,
          storesUnreadable: 0,
          checkedAt: now,
        );
        return;
      }
      final sweep = await ref.read(conversationPresenceSweepProvider)();
      final removable = <UnresumableSession>[];
      final uncertain = <UnresumableSession>[];
      for (final candidate in candidates) {
        final verdict = PromiseVerdict.of(
          sweep.presenceOf(
            agentId: candidate.agentId,
            environmentId: candidate.environmentId,
            conversationId: candidate.session.externalSessionId ?? '',
          ),
        );
        final row = UnresumableSession(
          session: candidate.session,
          agentName: candidate.agentName,
          verdict: verdict,
        );
        switch (verdict) {
          case PromiseVerdict.unkept:
            removable.add(row);
          case PromiseVerdict.unknown:
            uncertain.add(row);
          case PromiseVerdict.kept:
            // The promise was kept. Nothing to say and nothing to offer.
            break;
        }
      }
      state = UnresumableReview(
        removable: removable,
        uncertain: uncertain,
        storesRead: sweep.storesRead,
        storesUnreadable: sweep.storesUnreadable,
        checkedAt: sweep.checkedAt,
      );
    } finally {
      _running = false;
    }
  }

  /// Removes the rows this reading found removable, and nothing else.
  ///
  /// [ids] is intersected with [UnresumableReview.removable] rather than
  /// trusted: the sheet can be open while a session starts, and a row the
  /// reading has not judged must not be deletable through a set that names it.
  ///
  /// `deleteFromCli: false`, and provably so rather than as a default: every
  /// row here is one whose store was read to the end *without* the conversation
  /// in it, so there is no transcript to purge. Offering the choice would be
  /// offering to delete a file we have just established does not exist.
  void remove(Iterable<String> ids) {
    final allowed = {for (final row in state.removable) row.session.id};
    final targets = ref
        .read(sessionBulkDeleteProvider)
        .resolve(ids.where(allowed.contains));
    if (targets.isEmpty) return;
    ref.read(sessionBulkDeleteProvider).run(targets, deleteFromCli: false);
    final removed = {for (final row in targets.natives) row.id};
    state = UnresumableReview(
      removable: [
        for (final row in state.removable)
          if (!removed.contains(row.session.id)) row,
      ],
      uncertain: state.uncertain,
      storesRead: state.storesRead,
      storesUnreadable: state.storesUnreadable,
      checkedAt: state.checkedAt,
    );
  }

  /// Starts a fresh conversation **in** [sessionId], keeping the row.
  ///
  /// The other answer, and for most rows the better one: the promise is simply
  /// made again. Everything the user associates with the row — its title, its
  /// age, its pins, its notes, its place in a lineage — is what a delete would
  /// have thrown away, and reuse is already how the launcher continues a
  /// session (see `SessionLaunchRequest.restartSessionId`).
  Future<Session> restart(String sessionId) async {
    final row = ref.read(sessionDaoProvider).getById(sessionId);
    if (row == null) {
      throw StateError('That session is no longer in the workspace.');
    }
    final repository = ref
        .read(repositoryDaoProvider)
        .getById(row.repositoryId);
    if (repository == null) {
      throw StateError(
        'This session\'s repository is no longer in the workspace.',
      );
    }
    final installation = ref
        .read(agentInstallationDaoProvider)
        .getById(row.agentInstallationId);
    if (installation == null) {
      throw StateError('This session\'s agent installation is gone.');
    }
    final launched = await ref.read(sessionLauncherProvider).launch(
      SessionLaunchRequest(
        repository: repository,
        installation: installation,
        title: row.title,
        // A conversation that never existed is a new one, whatever the row's
        // age says — so the *new session* permission mode, and the row's own
        // recorded choice still wins inside `permissionFor`.
        purpose: SessionPurpose.newSession,
        surface: row.surface,
        restartSessionId: row.id,
      ),
    );
    // Off the list either way: it either started, or it threw before writing
    // anything and the next reading will find it again.
    state = UnresumableReview(
      removable: [
        for (final entry in state.removable)
          if (entry.session.id != sessionId) entry,
      ],
      uncertain: [
        for (final entry in state.uncertain)
          if (entry.session.id != sessionId) entry,
      ],
      storesRead: state.storesRead,
      storesUnreadable: state.storesUnreadable,
      checkedAt: state.checkedAt,
    );
    return launched.session;
  }

  /// The rows worth reading a store for — the free half.
  ///
  /// Every lookup here is in memory: one `getAll()`, a map of installations
  /// built once, and one pane lookup per row. Counted by
  /// `unresumable_sessions_cost_test.dart`, which asserts it stays flat.
  List<_Candidate> _screen() {
    final now = ref.read(clockProvider).nowUtc();
    final registry = ref.read(agentRegistryProvider);
    final installations = {
      for (final installation
          in ref.read(agentInstallationDaoProvider).getAll())
        installation.id: installation,
    };
    final launcher = ref.read(sessionLauncherProvider);
    final repositories = ref.read(repositoryDaoProvider);
    final out = <_Candidate>[];
    for (final session in ref.read(sessionDaoProvider).getAll()) {
      final installation = installations[session.agentInstallationId];
      if (installation == null) continue;
      final descriptor = registry.byId(installation.agentId);
      final screening = screenSessionPromise(
        session,
        agentAssignsSessionId:
            descriptor?.launch.sessionIdAssignment.isSupported ?? false,
        hostedLive: launcher.livePaneFor(session.id) != null,
        now: now,
      );
      if (screening != PromiseScreening.candidate) continue;
      // Where the agent would have written it — the same resolution
      // `refuseIfConversationMissing` uses, so the sweep is asked about the
      // store the resume path would have consulted.
      final directory =
          session.workingDirectory ??
          session.worktree ??
          repositories.getById(session.repositoryId)?.path;
      if (directory == null) continue;
      out.add(
        _Candidate(
          session: session,
          agentId: installation.agentId,
          agentName: registry.displayNameFor(installation.agentId),
          environmentId: directory.environmentId,
        ),
      );
    }
    return out;
  }
}

class _Candidate {
  const _Candidate({
    required this.session,
    required this.agentId,
    required this.agentName,
    required this.environmentId,
  });

  final Session session;
  final String agentId;
  final String agentName;
  final String environmentId;
}

/// A `NotifierProvider` and not autoDispose: a reading has an age, and losing
/// it because the sheet closed would make "checked 2m ago" impossible to say.
final unresumableSessionsProvider =
    NotifierProvider<UnresumableSessionsController, UnresumableReview>(
      UnresumableSessionsController.new,
    );
