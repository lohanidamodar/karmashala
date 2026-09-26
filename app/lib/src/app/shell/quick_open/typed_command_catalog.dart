import '../../../features/workspaces/data/workspace_data.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../../core/util/clock_provider.dart';
import '../../../features/agents/application/agent_providers.dart';
import '../../../features/cli_detection/application/cli_detection_providers.dart';
import '../../../features/environments/application/environment_providers.dart';
import '../../../features/notifications/application/attention_inbox.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/sessions/application/session_defaults.dart';
import '../../../features/sessions/application/session_last_active_providers.dart';
import '../../../features/sessions/application/session_launcher.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/application/session_status_providers.dart';
import '../../../features/terminal/application/terminal_profiles.dart';
import 'quick_open_cache.dart';
import 'typed_command.dart';

/// Reads the workspace into a [CommandCatalog] — once per palette, and only
/// when a verb was typed. Every fact comes from the provider that owns it.
CommandCatalog readCommandCatalog(
  ProviderContainer container, {
  Set<String> notGitProjectIds = const {},
}) {
  final read = container.read;
  final now = read(clockProvider).nowUtc();
  final registry = read(agentRegistryProvider);
  final environments = read(executionEnvironmentDaoProvider).getAll();
  final installations = read(agentInstallationDaoProvider).getAll();
  final workspace = read(workspaceDataProvider);
  final sessionDao = read(sessionsDataProvider);
  final importedDao = read(importedSessionsProvider);
  final lastActiveOf = read(sessionLastActiveProvider);
  final statusOf = read(sessionStatusLookupProvider);
  final launcher = read(sessionLauncherProvider);
  final defaults = read(sessionDefaultsProvider);
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
        if (i.environmentId == environmentId)
          CommandInstallation(id: i.id, agentId: i.agentId),
    ];
    final lastUsed = lastUsedInstallation[project.id];
    final defaultId = installed.any((i) => i.id == lastUsed)
        ? lastUsed
        : defaults.forEnvironment(environmentId).installation?.id;
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
  return CommandCatalog(
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
    searchConversations: (query) => _searchConversations(container, query),
  );
}

/// What was *said*, through the one conversation search quick open already
/// runs, mapped to the session each hit opens.
List<ConversationMatch> _searchConversations(
  ProviderContainer container,
  String query,
) {
  final hits = container
      .read(sessionSearchServiceProvider)
      .search(query, limit: kCommandSuggestionLimit)
      .hits;
  final sessionDao = container.read(sessionsDataProvider);
  final importedDao = container.read(importedSessionsProvider);
  return [
    for (final hit in hits)
      if (sessionDao.getByExternalSessionId(hit.sessionId)?.id ??
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
/// name — `claude`, `codex`, `antigravity` — or its id when two would clash.
List<CommandAgent> _agents(AgentRegistry registry) {
  final named = [
    for (final descriptor in registry.descriptors)
      (
        id: descriptor.id,
        token: commandSlug(
          registry.displayNameFor(descriptor.id).split(' ').first,
        ),
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
      ),
  ];
}

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
