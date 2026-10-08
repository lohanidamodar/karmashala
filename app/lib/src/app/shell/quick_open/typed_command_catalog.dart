import '../../../features/workspaces/data/workspace_data.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../../core/util/clock_provider.dart';
import '../../../features/agents/application/agent_providers.dart';
import '../../../features/agents/application/folded_installations.dart';
import '../../../features/settings/application/settings_controller.dart';
import '../../../features/environments/application/environment_providers.dart';
import '../../../features/notifications/application/attention_inbox.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/sessions/application/new_session_memory.dart';
import '../../../features/sessions/application/session_defaults.dart';
import '../../../features/sessions/application/session_last_active_providers.dart';
import '../../../features/sessions/application/session_launcher.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/application/session_status_providers.dart';
import '../../../features/remote/application/remote_approval_bindings.dart';
import '../../../features/sessions/application/session_engine_provider.dart';
import '../../../features/sessions/presentation/approval_request_card.dart'
    show BoardApproval, ProviderReader, boardApprovalOffersBy;
import '../../../features/terminal/application/terminal_profiles.dart';
import 'package:karmashala_remote/remote.dart' show RemoteQuestion;
import '../../../features/overview/application/overview_prefs.dart'
    show launchInBackgroundProvider;
import 'quick_open_cache.dart';
import 'typed_command.dart';

/// Reads the workspace into a [CommandCatalog] — once per palette, and only
/// when a verb was typed. Every fact comes from the provider that owns it.
CommandCatalog readCommandCatalog(
  ProviderContainer container, {
  Set<String> notGitProjectIds = const {},
  List<ConversationHit> Function(String query)? conversationHits,
}) {
  final read = container.read;
  final now = read(clockProvider).nowUtc();
  final registry = read(agentRegistryProvider);
  final environments = read(environmentsDataProvider).getAll();
  final installations = read(agentInstallationsDataProvider).getAll();
  final workspace = read(workspaceDataProvider);
  final sessionDao = read(sessionsDataProvider);
  final importedDao = read(importedSessionsProvider);
  final lastActiveOf = read(sessionLastActiveProvider);
  final statusOf = read(sessionStatusLookupProvider);
  final launcher = read(sessionLauncherProvider);
  final defaults = read(sessionDefaultsProvider);
  final memory = read(newSessionMemoryProvider);
  final inbox = read(attentionInboxProvider);
  final profiles = read(terminalProfilesProvider);
  final cache = read(quickOpenCacheProvider.notifier);
  final projects = read(sortedProjectsProvider);

  final waiting = [
    for (final item in inbox.items)
      if (item.kind == InboxItemKind.needsApproval) item,
  ]..sort((a, b) => a.at.compareTo(b.at));
  final waitingIds = {for (final item in waiting) item.session.openId};

  final agents = _agents(registry);
  final envById = {for (final e in environments) e.id: e};
  final commandEnvironments = _environments(environments);

  // Every session once, with the recency order the Sessions group uses.
  final rows =
      <
        ({
          SessionActivityOrder order,
          String projectId,
          Session? native,
          ImportedSession? imported,
        })
      >[];
  for (final project in projects) {
    for (final repository in workspace.repositoriesOf(project.id)) {
      for (final session in sessionDao.getByRepository(repository.id)) {
        rows.add((
          order: (
            lastActive: lastActiveOf(session.id),
            createdAt: session.createdAt,
          ),
          projectId: project.id,
          native: session,
          imported: null,
        ));
      }
      for (final session in importedDao.getByRepository(repository.id)) {
        rows.add((
          order: (
            lastActive: lastActiveOf(
              session.id,
              storeModifiedAt: session.updatedAt,
            ),
            createdAt: session.createdAt,
          ),
          projectId: project.id,
          native: null,
          imported: session,
        ));
      }
    }
  }
  rows.sort((a, b) => compareByLastActive(a.order, b.order));

  final projectNames = {for (final p in projects) p.id: p.name};
  final installById = {for (final i in installations) i.id: i};
  final sessionTokens = uniqueTokens([
    for (final row in rows)
      (
        id: row.native?.id ?? row.imported!.id,
        token: _sessionToken(row.native?.title ?? row.imported!.displayTitle),
      ),
  ]);

  final sessions = <CommandSession>[];
  final projectRecency = <String, int>{};
  final projectWaiting = <String>{};
  final lastUsedInstallation = <String, String>{};
  for (var rank = 0; rank < rows.length; rank++) {
    final row = rows[rank];
    final known = row.order.lastActive.isKnown;
    if (known) projectRecency.putIfAbsent(row.projectId, () => rank);
    final native = row.native;
    if (native != null) {
      lastUsedInstallation.putIfAbsent(
        row.projectId,
        () => native.agentInstallationId,
      );
      final agentId = installById[native.agentInstallationId]?.agentId;
      final report = statusOf(native.id);
      final live = launcher.livePaneFor(native.id) != null;
      final isWaiting =
          waitingIds.contains(native.id) ||
          (report?.hasOpenPrompt ?? false) ||
          (report?.hasOpenQuestion ?? false);
      if (isWaiting) projectWaiting.add(row.projectId);
      final dot = isWaiting
          ? SessionDot.waiting
          : !live
          ? SessionDot.stopped
          : switch (report?.status) {
              AgentActivityStatus.working => SessionDot.working,
              AgentActivityStatus.idle => SessionDot.idle,
              _ => SessionDot.unknown,
            };
      final descriptor = agentId == null ? null : registry.byId(agentId);
      final agentName = agentId == null ? '' : registry.displayNameFor(agentId);
      final fork = SessionForkPlan.decide(
        descriptor: descriptor,
        agentName: agentId == null ? 'this agent' : agentName,
        externalSessionId: native.externalSessionId,
      );
      final runs =
          live ||
          native.status.claimsLive ||
          read(sessionEngineProvider).isActive(native.id) ||
          launcher.heldByHostOnly(native.id);
      final open = (report?.hasOpenQuestion ?? false)
          ? read(chatOpenQuestionProvider(native.id))
          : null;
      final repository = workspace.repository(native.repositoryId);
      sessions.add(
        CommandSession(
          id: native.id,
          title: native.title,
          token: sessionTokens[native.id]!,
          projectId: row.projectId,
          projectName: projectNames[row.projectId] ?? '',
          agentName: agentName,
          dot: dot,
          ageLabel: row.order.lastActive.label(now),
          recencyRank: known ? rank : null,
          live: live,
          endRefusal: live ? null : 'Not running, so there is nothing to end.',
          stopRefusal: _stopRefusal(
            live: live,
            report: report,
            descriptor: descriptor,
            agentName: agentName,
          ),
          forkRefusal: fork.isRefused ? fork.explanation : null,
          archiveRefusal: native.isArchived
              ? 'Already archived.'
              : runs
              ? 'Still running — end it first.'
              : null,
          question: switch (open?.value) {
            final question? => _questionOf(question),
            null => null,
          },
          questionUnread: open != null && open.value == null,
          approval: (report?.hasOpenPrompt ?? false)
              ? _approvalOf(read, native.id, report!)
              : null,
          branch: repository == null
              ? null
              : cache.factsFor(repository.id).branches.firstOrNull,
        ),
      );
    } else {
      final imported = row.imported!;
      final isWaiting = waitingIds.contains(imported.id);
      if (isWaiting) projectWaiting.add(row.projectId);
      sessions.add(
        CommandSession(
          id: imported.id,
          title: imported.displayTitle,
          token: sessionTokens[imported.id]!,
          projectId: row.projectId,
          projectName: projectNames[row.projectId] ?? '',
          agentName: registry.displayNameFor(imported.cli),
          imported: true,
          dot: isWaiting ? SessionDot.waiting : SessionDot.unknown,
          ageLabel: row.order.lastActive.label(now),
          recencyRank: known ? rank : null,
        ),
      );
    }
  }

  final projectTokens = uniqueTokens([
    for (final p in projects) (id: p.id, token: commandProjectToken(p.name)),
  ]);
  final commandProjects = <CommandProject>[];
  for (final project in projects) {
    final environmentId = project.environmentId;
    final installed = [
      for (final i in installations)
        if (i.environmentId == environmentId &&
            registry.adapterFor(i.agentId) != null)
          CommandInstallation(id: i.id, agentId: i.agentId),
    ];
    // What the dialog opens on: the agent and form last started here, then
    // the last session's, then the machine's default.
    final lastUsed = [
      memory.installationFor(project.id),
      lastUsedInstallation[project.id],
    ].where((id) => installed.any((i) => i.id == id)).firstOrNull;
    final defaultId =
        lastUsed ?? defaults.forEnvironment(environmentId).installation?.id;
    final firstRepository = workspace.repositoriesOf(project.id).firstOrNull;
    final branches = firstRepository == null
        ? const <String>[]
        : cache.factsFor(firstRepository.id).branches;
    commandProjects.add(
      CommandProject(
        id: project.id,
        name: project.name,
        token: projectTokens[project.id]!,
        environmentId: environmentId,
        recencyRank: projectRecency[project.id],
        waiting: projectWaiting.contains(project.id),
        installations: installed,
        defaultInstallationId: defaultId,
        branch: branches.firstOrNull,
        notGit: notGitProjectIds.contains(project.id),
        terminals: {
          for (final env in environments)
            env.id: _terminalTarget(
              root: project.root,
              projectName: project.name,
              from: envById[environmentId],
              to: env,
              profiles: profiles,
            ),
        },
      ),
    );
  }

  final oldest = waiting.firstOrNull;
  final scratch = scratchDefaultInstallation(
    [
      for (final i in installations)
        if (registry.adapterFor(i.agentId) != null) i,
    ],
    registry,
    read(settingsControllerProvider),
  );
  return CommandCatalog(
    launchInBackground: read(launchInBackgroundProvider),
    scratchInstallation: scratch == null
        ? null
        : CommandInstallation(id: scratch.id, agentId: scratch.agentId),
    projects: commandProjects,
    sessions: sessions,
    environments: commandEnvironments,
    agents: agents,
    oldestWaiting: oldest == null
        ? null
        : CommandWaiting(
            itemId: oldest.id,
            sessionId: oldest.session.openId,
            imported: oldest.session.imported,
            title: oldest.session.label,
            detail: oldest.detail,
          ),
    searchConversations: conversationHits == null
        ? null
        : (query) => _saidIn(container, conversationHits(query)),
  );
}

/// What was *said*, through the one conversation search quick open already
/// runs, mapped to the session each hit opens.
List<ConversationMatch> _saidIn(
  ProviderContainer container,
  List<ConversationHit> hits,
) {
  final sessionDao = container.read(sessionsDataProvider);
  final importedDao = container.read(importedSessionsProvider);
  return [
    for (final hit in hits)
      if (sessionDao.getByExternalSessionId(hit.sessionId)?.id ??
              switch (hit.rowId) {
                final rowId? => sessionDao.getById(rowId)?.id,
                null => null,
              } ??
              importedDao.getByExternal(hit.cli, hit.sessionId)?.id
          case final openId?)
        (sessionId: openId, excerpt: hit.excerpt),
  ];
}

String _sessionToken(String title) {
  final slug = commandSlug(title);
  return slug.isEmpty ? 'session' : slug;
}

/// One entry per agent the registry knows, typed by the first word of its
/// name — `codex`, `antigravity`, `grok`. Where two agents share that word,
/// as Claude Code and Claude Code · Chat do, each is typed by its whole name
/// instead — `claude-code`, `claude-acp` — and only a clash that survives
/// even that falls back to the id.
List<CommandAgent> _agents(AgentRegistry registry) {
  final firstWords = <String, int>{};
  for (final descriptor in registry.descriptors) {
    final word = _firstWordSlug(registry.displayNameFor(descriptor.id));
    firstWords[word] = (firstWords[word] ?? 0) + 1;
  }
  final named = [
    for (final descriptor in registry.descriptors)
      (
        id: descriptor.id,
        token: switch (registry.displayNameFor(descriptor.id)) {
          final name when (firstWords[_firstWordSlug(name)] ?? 0) > 1 =>
            commandSlug(name),
          final name => _firstWordSlug(name),
        },
      ),
  ];
  final tokens = uniqueTokens([
    for (final n in named) (id: n.id, token: n.token.isEmpty ? n.id : n.token),
  ]);
  return [
    for (final n in named)
      CommandAgent(
        agentId: n.id,
        token: tokens[n.id]!,
        displayName: registry.displayNameFor(n.id),
        familyName: registry.formsOf(n.id).displayName,
        formLabel: registry.formOf(n.id).label,
      ),
  ];
}

String _firstWordSlug(String displayName) =>
    commandSlug(displayName.split(' ').first);

List<CommandEnvironment> _environments(List<ExecutionEnvironment> all) {
  final tokens = uniqueTokens([
    for (final env in all)
      (
        id: env.id,
        token: switch (env.kind) {
          EnvironmentKind.windowsNative => 'windows',
          EnvironmentKind.wsl => commandSlug(env.wslDistribution ?? env.name),
          _ => commandSlug(env.name),
        },
      ),
  ]);
  return [
    for (final env in all)
      CommandEnvironment(
        id: env.id,
        token: tokens[env.id]!.isEmpty ? env.id : tokens[env.id]!,
        label: environmentLabel(env) ?? env.name,
      ),
  ];
}

CommandQuestion _questionOf(RemoteQuestion question) {
  final first = question.questions.firstOrNull;
  return CommandQuestion(
    toolUseId: question.toolUseId,
    options: [for (final o in first?.options ?? const []) o.label],
    refusal: question.questions.length > 1
        ? 'It asks ${question.questions.length} questions — answer them in '
              'its view.'
        : first == null || first.options.isEmpty
        ? 'It offers no options to pick — answer it in its view.'
        : first.multiSelect
        ? 'It takes several choices — answer it in its view.'
        : null,
  );
}

/// The approval [report] holds open, as the board would answer it.
CommandApproval _approvalOf(
  ProviderReader read,
  String sessionId,
  AgentStatusReport report,
) {
  final ask = report.toolAsk;
  final offers = boardApprovalOffersBy(read, sessionId);
  const only = 'Only its terminal can answer this prompt.';
  return CommandApproval(
    subject: ask == null ? '' : summarizeToolAsk(ask).subject,
    folder: ask?.cwd ?? '',
    toolName: ask?.toolName ?? '',
    allowRefusal: offers.isEmpty
        ? only
        : offers.contains(BoardApproval.allow)
        ? null
        : 'This prompt names no way to allow.',
    denyRefusal: offers.isEmpty
        ? only
        : offers.contains(BoardApproval.deny)
        ? null
        : 'This prompt names no way to decline.',
  );
}

/// Only a prompt the agent itself advertises an interrupt for is pressed: Esc
/// in an approval would *answer* it, and at an idle prompt it does nothing.
String? _stopRefusal({
  required bool live,
  required AgentStatusReport? report,
  required AgentDescriptor? descriptor,
  required String agentName,
}) {
  if (!live) return 'Not running, so there is nothing to interrupt.';
  if ((report?.hasOpenPrompt ?? false) || (report?.hasOpenQuestion ?? false)) {
    return 'It is asking you something — Esc would answer it. Use answer.';
  }
  final interrupts =
      descriptor?.grid.working.any(
        (m) => m.contains.toLowerCase().contains('esc to interrupt'),
      ) ??
      false;
  if (!interrupts) {
    return '${agentName.isEmpty ? 'This agent' : agentName} names no '
        'interrupt key.';
  }
  if (report?.status != AgentActivityStatus.working) {
    return 'Not in the middle of a turn, so there is nothing to interrupt.';
  }
  return null;
}

/// The project's folder in [to], and the terminal profile that opens there.
CommandTerminalTarget _terminalTarget({
  required EnvironmentPath root,
  required String projectName,
  required ExecutionEnvironment? from,
  required ExecutionEnvironment to,
  required List<TerminalProfile> profiles,
}) {
  final label = environmentLabel(to) ?? to.name;
  final profileId = switch (to.kind) {
    EnvironmentKind.windowsNative ||
    EnvironmentKind.localPosix => profiles.firstOrNull?.id,
    EnvironmentKind.wsl => TerminalProfile.wslId(to.wslDistribution ?? to.name),
    EnvironmentKind.ssh =>
      to.sshHostId == null ? null : TerminalProfile.ssh(to.sshHostId!).id,
  };
  if (profileId == null || !profiles.any((p) => p.id == profileId)) {
    return CommandTerminalTarget(
      refusal: 'No terminal for $label on this machine',
    );
  }
  if (from == null) {
    return CommandTerminalTarget(
      refusal: 'The environment $projectName lives in is no longer recorded',
    );
  }
  try {
    final path = const PathTranslator().translate(root, from: from, to: to);
    return CommandTerminalTarget(
      profileId: profileId,
      workingDirectory: path.path,
    );
  } on PathTranslationException {
    return CommandTerminalTarget(
      refusal:
          '$projectName lives in ${environmentLabel(from) ?? from.name}, '
          'which $label cannot reach',
    );
  }
}
