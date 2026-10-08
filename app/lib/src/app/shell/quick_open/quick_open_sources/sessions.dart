part of '../quick_open_sources.dart';

// Session and conversation rows, and what picking or resuming one does.

extension QuickOpenSessionSources on QuickOpenSources {
  // --- sessions ------------------------------------------------------------

  /// Native and imported sessions, most recently active first. Only *free*
  /// whereabouts: a transcript stat per session would be a disk sweep. A step
  /// narrows them to one [projectId] or one [repositoryId]; the rows are the
  /// full list's own, so picking one does exactly what it does there.
  List<QuickOpenItem> _sessions({String? projectId, String? repositoryId}) {
    final container = ProviderScope.containerOf(context, listen: false);
    final sessionDao = ref.read(sessionsDataProvider);
    final importedDao = ref.read(importedSessionsProvider);
    final workspace = ref.read(workspaceDataProvider);
    final installations = ref.read(agentInstallationsDataProvider);
    final registry = ref.read(agentRegistryProvider);
    final panes = ref.read(paneSessionsProvider);
    final selectedRepository = ref.read(selectedRepositoryIdProvider);
    final lastActiveOf = ref.read(sessionLastActiveProvider);
    final now = ref.read(clockProvider).nowUtc();

    final entries =
        <({SessionActivityOrder order, QuickOpenItem Function(double) make})>[];

    for (final project in ref.read(sortedProjectsProvider)) {
      if (projectId != null && project.id != projectId) continue;
      for (final repository in workspace.repositoriesOf(project.id)) {
        if (repositoryId != null && repository.id != repositoryId) continue;
        final where = '${project.name} · ${repository.name}';
        final here = repository.id == selectedRepository
            ? _selectedRepoBoost
            : 0.0;

        for (final session in sessionDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(
            installations.getById(session.agentInstallationId)?.agentId ?? '',
          );
          final note = _cheapWhereabouts(session, panes);
          final lastActive = lastActiveOf(session.id);
          entries.add((
            order: (lastActive: lastActive, createdAt: session.createdAt),
            make: (recency) => QuickOpenItem(
              id: 'session/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.title,
              // The age of the newest reading, or nothing when we hold none —
              // never "just now" for a session we cannot speak for (§19).
              subtitle: [
                where,
                agent,
                ?note,
                ?lastActive.label(now),
              ].join(' · '),
              detail: session.isArchived
                  ? 'archived'
                  : _statusWord(session.status),
              icon: AppIcons.chatCircle,
              keywords: [
                agent,
                session.status.name,
                if (session.isArchived) 'archived',
                if (session.useWorktree) 'worktree',
                ?session.worktree?.path,
              ],
              weight: _sessionWeight + here + recency,
              opensTab: true,
              onSelect: () => dismiss(pickSession(session.id)),
              onResume: _stopped(container, session.id)
                  ? () => dismiss(resumeSession(session.id))
                  : null,
            ),
          ));
        }

        for (final session in importedDao.getByRepository(repository.id)) {
          final agent = registry.displayNameFor(session.cli);
          final lastActive = lastActiveOf(
            session.id,
            storeModifiedAt: session.updatedAt,
          );
          entries.add((
            order: (lastActive: lastActive, createdAt: session.createdAt),
            make: (recency) => QuickOpenItem(
              id: 'imported/${session.id}',
              group: QuickOpenGroup.sessions,
              title: session.displayTitle,
              subtitle: [
                where,
                agent,
                'imported',
                ?lastActive.label(now),
              ].join(' · '),
              detail: session.isSubagent ? 'subagent' : null,
              icon: AppIcons.clockCounterClockwise,
              keywords: [agent, 'imported', session.preview],
              weight: _sessionWeight + here + recency,
              opensTab: true,
              onSelect: () =>
                  dismiss(() => focusSession(session.id, imported: true)),
            ),
          ));
        }
      }
    }

    // Recency is a rank, not a duration: the newest is worth [_recencySpread]
    // over the stalest whether the gap is an hour or a year.
    entries.sort((a, b) => compareByLastActive(a.order, b.order));
    final last = entries.length - 1;
    return [
      for (var i = 0; i < entries.length; i++)
        entries[i].make(
          last == 0 ? _recencySpread : _recencySpread * (1 - i / last),
        ),
    ];
  }

  String? _cheapWhereabouts(Session session, PaneSessions panes) {
    if (panes.paneOf(session.id, where: (liveness) => liveness.isLive) !=
        null) {
      return 'running here';
    }
    if (session.surface == SessionSurface.external) {
      return 'opened in an external terminal';
    }
    return null;
  }

  /// A native session picked by name: shown, never resumed — a resume sends
  /// the conversation back as context, which costs tokens, and a pick is
  /// usually a look. With "Resume and start sessions in the background" on,
  /// one nothing runs is shown in the Agent dashboard's peek, with no tab;
  /// anything else opens as [focusSession] does.
  void Function() pickSession(String sessionId) {
    final container = ProviderScope.containerOf(context, listen: false);
    return () {
      if (!container.read(launchInBackgroundProvider) ||
          !_stopped(container, sessionId)) {
        unawaited(focusSession(sessionId, imported: false));
        return;
      }
      openOverviewTab(ref);
      peekOnDashboard(container, sessionId);
    };
  }

  /// A stopped session's explicit Resume — Shift+Enter or the row's button:
  /// where the person is while the background setting is on (its card
  /// peeked, or a notice with Open), into its tab while it is off.
  void Function() resumeSession(String sessionId) {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    return () {
      if (!container.read(launchInBackgroundProvider)) {
        unawaited(focusSession(sessionId, imported: false));
        return;
      }
      unawaited(() async {
        final result = await container
            .read(overviewResumerProvider)
            .resume(sessionId);
        if (result.message case final message?) {
          messenger?.showSnackBar(SnackBar(content: Text(message)));
        }
        if (result.isFailure) return;
        announceBackgroundLaunch(
          container,
          sessionId: sessionId,
          messenger: messenger,
        );
      }());
    };
  }

  /// Whether nothing runs [sessionId]: what a Resume would bring back.
  static bool _stopped(ProviderContainer container, String sessionId) {
    final session = container.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return false;
    final launcher = container.read(sessionLauncherProvider);
    return launcher.livePaneFor(sessionId) == null &&
        !launcher.heldByHostOnly(sessionId) &&
        !session.status.claimsLive &&
        !container.read(sessionEngineProvider).isActive(sessionId);
  }

  /// The New-session dialog, its "Keep working here" starting as the
  /// background setting says; a session started there is pointed at.
  Future<void> _newSessionDialog({SessionDestination? destination}) {
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    return NewSessionDialog.show(
      context,
      destination: destination,
      keepHere: container.read(launchInBackgroundProvider),
      onStarted: (session, {required keptHere}) {
        if (!keptHere) return;
        announceBackgroundLaunch(
          container,
          sessionId: session.id,
          messenger: messenger,
          started: true,
        );
      },
    );
  }

  /// Selects a session and everything above it, through the one walk that
  /// already exists for a clicked toast and a clicked tray item.
  Future<void> focusSession(String openId, {required bool imported}) async {
    focusWatchedSession(
      ProviderScope.containerOf(context, listen: false),
      openId: openId,
      imported: imported,
    );
    ref.read(shellControllerProvider.notifier).focusPane(ShellPane.detail);
    // Picking the session already selected moves nothing the shell hears.
    phone?.showWorkbench();

    // And actually open it: picking a session by name is a request to be *in*
    // it. `openNative` decides between reattach, resume and select.
    final result = await _open(openId, imported: imported);
    final message = result.message;
    if (message == null || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Reattach, resume or select — whichever [openId] needs.
  Future<ExplorerResult> _open(String openId, {required bool imported}) {
    final actions = ref.read(explorerActionsProvider);
    if (!imported) return actions.openNative(openId);
    final record = ref.read(importedSessionsProvider).getById(openId);
    return record == null
        ? Future.value(const ExplorerResult(ExplorerOutcome.selected))
        : actions.openImported(record);
  }

  // --- conversations ------------------------------------------------------

  /// One row per conversation something was *said* in, never filtered on the
  /// filesystem, so a row whose worktree is gone still opens.
  List<QuickOpenItem> conversations(
    List<ConversationHit> hits,
    String query, {
    DateTime? now,
  }) {
    if (hits.isEmpty) return const [];
    final sessionDao = ref.read(sessionsDataProvider);
    final importedDao = ref.read(importedSessionsProvider);
    final registry = ref.read(agentRegistryProvider);
    final at = now ?? DateTime.now().toUtc();

    final items = <QuickOpenItem>[];
    final seen = <String>{};
    // One row per thread: a switched one holds several conversations.
    final opened = <String>{};
    for (var rank = 0; rank < hits.length; rank++) {
      final hit = hits[rank];
      if (!seen.add(hit.sessionId)) continue;
      // An earlier agent's part of a switched thread opens its session.
      final native =
          sessionDao.getByExternalSessionId(hit.sessionId) ??
          switch (hit.rowId) {
            final rowId? => sessionDao.getById(rowId),
            null => null,
          };
      final imported = native == null
          ? importedDao.getByExternal(hit.cli, hit.sessionId)
          : null;
      final openId = native?.id ?? imported?.id;
      if (openId == null || !opened.add(openId)) continue;
      final title = native?.title ?? imported!.displayTitle;
      final agent = registry.displayNameFor(hit.cli);
      // A ranked page carries its own count; a raw turn list counts itself.
      final matches = hit.matches > 1
          ? hit.matches
          : hits.where((h) => h.sessionId == hit.sessionId).length;
      items.add(
        QuickOpenItem(
          id: 'conversation/${hit.sessionId}',
          group: QuickOpenGroup.conversations,
          title: title,
          subtitle: hit.excerpt,
          // The age of the reading, not of the conversation: the index is only
          // as current as the trigger that last read that transcript (§19).
          detail: [
            if (native?.isArchived ?? false) 'archived',
            if (matches > 1) '$matches matches',
            agent,
            if (hit.indexedAt != null)
              'indexed ${describeAge(at.difference(hit.indexedAt!))}',
          ].join('  ·  '),
          icon: AppIcons.chatCircleDots,
          // FTS5 has already decided this row matches; carrying the query as a
          // keyword stops the fuzzy scorer dropping an excerpt that lacks it.
          keywords: [query, agent],
          weight:
              _conversationWeight +
              _conversationRankSpread * (1 - rank / hits.length),
          opensTab: true,
          onSelect: () =>
              dismiss(() => focusSession(openId, imported: native == null)),
        ),
      );
    }
    return items;
  }
}

/// A session's status as the palette says it: a plain word, or nothing for
/// the states that claim nothing — "unknown" and "created" read as faults.
String? _statusWord(SessionStatus status) => switch (status) {
  SessionStatus.running => 'running',
  SessionStatus.idle => 'idle',
  SessionStatus.completed => 'done',
  SessionStatus.failed => 'failed',
  SessionStatus.cancelled => 'stopped',
  SessionStatus.created || SessionStatus.unknown => null,
};
