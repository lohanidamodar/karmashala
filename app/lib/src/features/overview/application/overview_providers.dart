import 'package:flutter/foundation.dart' show immutable, mapEquals;

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ForgeReadingChanged;
import 'package:karmashala_git/github.dart' show PullRequestSnapshot;
import 'package:karmashala_git/repositories.dart' show Checkout;
import 'package:karmashala_notifications/attention.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/data/agents_data.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/agent_state_providers.dart';
import '../../notifications/application/attention_inbox.dart';
import '../../projects/application/projects_controller.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../explorer/application/workspace_session_entry.dart';
import '../../workspaces/application/workspaces_controller.dart';
import '../../workspaces/data/workspace_data.dart';
import 'overview_board.dart';
import 'overview_prefs.dart';
import 'overview_tiles.dart';

/// What the Board files sessions by: each session's project, machine and
/// agent, and the lanes in reading order — this machine, then WSL, then SSH.
final overviewFactsProvider = Provider.autoDispose<OverviewFacts>((ref) {
  final projects = ref.watch(sortedProjectsProvider);
  final environments = [...ref.watch(environmentsControllerProvider)]
    ..sort((a, b) {
      final rank = _rank(a.kind).compareTo(_rank(b.kind));
      return rank != 0 ? rank : _label(a).compareTo(_label(b));
    });
  final workspace = ref.read(workspaceDataProvider);
  final installations = ref.read(agentInstallationsDataProvider);
  // By name, as the Explorer lists them.
  final contexts = [...ref.watch(workspacesControllerProvider)]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final contextOfProject = {
    for (final project in projects) project.id: project.workspaceId,
  };
  String? projectOf(WorkspaceSessionEntry entry) {
    final repositoryId =
        entry.native?.repositoryId ?? entry.imported?.repositoryId;
    return repositoryId == null
        ? null
        : workspace.repository(repositoryId)?.projectId;
  }

  return OverviewFacts(
    projectOf: projectOf,
    contextOf: (entry) => contextOfProject[projectOf(entry)],
    contexts: [
      for (final context in contexts) OverviewLaneKey(context.id, context.name),
    ],
    machineOf: (entry) => entry.directory?.environmentId,
    agentOf: (entry) =>
        entry.imported?.cli ??
        switch (entry.native) {
          final native? =>
            installations.getById(native.agentInstallationId)?.agentId,
          null => null,
        },
    projects: [
      for (final project in projects) OverviewLaneKey(project.id, project.name),
    ],
    machines: [
      for (final environment in environments)
        OverviewLaneKey(environment.id, _label(environment)),
    ],
  );
});

String _label(ExecutionEnvironment environment) =>
    environmentLabel(environment) ?? environment.name;

int _rank(EnvironmentKind kind) => switch (kind) {
  EnvironmentKind.windowsNative || EnvironmentKind.localPosix => 0,
  EnvironmentKind.wsl => 1,
  EnvironmentKind.ssh => 2,
};

/// The local midnight that began today, as UTC. Read once per build, never
/// from a timer, as the Activity lens reads its days.
DateTime _startOfToday(Ref ref) {
  final now = ref.read(clockProvider).nowUtc().toLocal();
  return DateTime(now.year, now.month, now.day).toUtc();
}

final _overviewOrderProvider = Provider.autoDispose<BoardOrderMemo>(
  (ref) => BoardOrderMemo(),
);

/// How the Board groups: the saved choice, or Project when it is Context and
/// no context is left to group by.
final overviewGroupByProvider = Provider.autoDispose<OverviewGroupBy>(
  (ref) => effectiveGroupBy(
    ref.watch(overviewPrefsProvider.select((p) => p.groupBy)),
    ref.watch(overviewFactsProvider),
  ),
);

/// **The Board**, from the Agents lens's own groups — so it honours Hide
/// while working and Show archived the way the lists do — filtered and laid
/// out as this device chose. Recomputed only when those inputs move.
final overviewBoardProvider = Provider.autoDispose<OverviewBoard>((ref) {
  final prefs = ref.watch(overviewPrefsProvider);
  return buildOverviewBoard(
    ref.watch(agentStateGroupsProvider),
    facts: ref.watch(overviewFactsProvider),
    filter: prefs.filter,
    groupBy: ref.watch(overviewGroupByProvider),
    startOfToday: _startOfToday(ref),
    memo: ref.watch(_overviewOrderProvider),
    subSessions: prefs.subSessions,
  );
});

final _overviewCountsOrderProvider = Provider.autoDispose<BoardOrderMemo>(
  (ref) => BoardOrderMemo(),
);

/// The Board as [overviewBoardProvider] draws it but with every state in:
/// what the counters count, so picking one state does not zero the others.
final overviewAllStatesBoardProvider = Provider.autoDispose<OverviewBoard>((
  ref,
) {
  final prefs = ref.watch(overviewPrefsProvider);
  final filter = prefs.filter;
  if (filter.allStates) return ref.watch(overviewBoardProvider);
  return buildOverviewBoard(
    ref.watch(agentStateGroupsProvider),
    facts: ref.watch(overviewFactsProvider),
    filter: OverviewFilter(
      projects: filter.projects,
      agents: filter.agents,
      machines: filter.machines,
    ),
    groupBy: ref.watch(overviewGroupByProvider),
    startOfToday: _startOfToday(ref),
    memo: ref.watch(_overviewCountsOrderProvider),
    subSessions: prefs.subSessions,
  );
});

/// The counters over the tiles: the strip's numbers and what ended today,
/// whatever state the tiles are narrowed to.
final overviewCountersProvider =
    Provider.autoDispose<({OverviewStrip strip, int doneToday})>((ref) {
      final board = ref.watch(overviewAllStatesBoardProvider);
      return (strip: _stripOf(ref, board), doneToday: doneTodayOf(board));
    });

/// The numbers over the Board, for the sessions it holds.
final overviewStripProvider = Provider.autoDispose<OverviewStrip>(
  (ref) => _stripOf(ref, ref.watch(overviewBoardProvider)),
);

OverviewStrip _stripOf(Ref ref, OverviewBoard board) {
  final items = ref.watch(attentionInboxProvider).items;
  final client = ref.watch(dataClientProvider);
  final told = client.sessionUsageChanges.listen((_) => ref.invalidateSelf());
  ref.onDispose(told.cancel);
  final statusOf = ref.read(sessionStatusLookupProvider);
  return summarizeStrip(
    board,
    now: ref.read(clockProvider).nowUtc(),
    startOfToday: _startOfToday(ref),
    waitingSince: (id) => statusOf(id)?.waitingSince,
    failingChecks: {
      for (final item in items)
        if (item.kind == InboxItemKind.checksFailed) item.session.openId,
    },
    usageLimited: {
      for (final item in items)
        if (item.kind == InboxItemKind.usageLimit) item.session.openId,
    },
    cost: (id) {
      final usage = client.sessionUsage[id];
      final amount = usage?.costAmount;
      return amount == null
          ? null
          : (amount: amount, currency: usage!.costCurrency);
    },
  );
}

/// The inbox's words about one session, by kind.
@immutable
class OverviewInboxDetails {
  const OverviewInboxDetails(this.byKind);

  final Map<InboxItemKind, String> byKind;

  String? operator [](InboxItemKind kind) => byKind[kind];

  @override
  bool operator ==(Object other) =>
      other is OverviewInboxDetails && mapEquals(other.byKind, byKind);

  @override
  int get hashCode => Object.hashAllUnordered(
    byKind.entries.map((e) => Object.hash(e.key, e.value)),
  );
}

/// What the inbox says about session [String], for its card's line. Compared
/// by value, so one session's item wakes only that card.
final overviewInboxDetailsProvider = Provider.autoDispose
    .family<OverviewInboxDetails, String>(
      (ref, sessionId) => ref.watch(
        attentionInboxProvider.select(
          (inbox) => OverviewInboxDetails({
            for (final item in inbox.items)
              if (item.session.openId == sessionId && item.detail != null)
                item.kind: item.detail!,
          }),
        ),
      ),
    );

/// The pull request on [EnvironmentPath] checkout as the server's delivery
/// poll last pushed it; null when none was pushed. Never asks for one.
final overviewPullRequestProvider = Provider.autoDispose
    .family<PullRequestSnapshot?, EnvironmentPath>((ref, checkout) {
      final client = ref.watch(dataClientProvider);
      final told = client.attentionChanges.listen((change) {
        if (change is ForgeReadingChanged && change.checkout == checkout) {
          ref.invalidateSelf();
        }
      });
      ref.onDispose(told.cancel);
      return client.forgeReadings[checkout]?.pullRequest;
    });

/// The peek's views of a session.
enum OverviewPeekTab { chat, terminal, files, subSessions }

/// Which card the keyboard is on, and which one the peek shows, on which tab.
@immutable
class OverviewFocus {
  const OverviewFocus({
    this.selected,
    this.peeked,
    this.editing = false,
    this.tab = OverviewPeekTab.chat,
    this.beside,
  });

  final String? selected;
  final String? peeked;

  /// A second session peeked beside [peeked], where the window is wide
  /// enough for two; null for one peek.
  final String? beside;

  /// The peek opened with its command approval's command editable.
  final bool editing;
  final OverviewPeekTab tab;

  @override
  bool operator ==(Object other) =>
      other is OverviewFocus &&
      other.selected == selected &&
      other.peeked == peeked &&
      other.editing == editing &&
      other.tab == tab &&
      other.beside == beside;

  @override
  int get hashCode => Object.hash(selected, peeked, editing, tab, beside);
}

class OverviewFocusController extends Notifier<OverviewFocus> {
  @override
  OverviewFocus build() => const OverviewFocus();

  void select(String? id) => state = OverviewFocus(
    selected: id,
    peeked: state.peeked,
    editing: state.editing,
    tab: state.tab,
    beside: state.beside,
  );

  /// Peeks [first] and [second] side by side, each on its chat.
  void peekSideBySide(String first, String second) =>
      state = OverviewFocus(selected: first, peeked: first, beside: second);

  /// Closes the second peek, keeping the first.
  void closeBeside() => state = OverviewFocus(
    selected: state.selected,
    peeked: state.peeked,
    editing: state.editing,
    tab: state.tab,
  );

  /// Peeks [id] on [tab], which is also where the keyboard now is; with
  /// [editing], its command approval's command is open to change.
  void peek(
    String id, {
    bool editing = false,
    OverviewPeekTab tab = OverviewPeekTab.chat,
  }) => state = OverviewFocus(
    selected: id,
    peeked: id,
    editing: editing,
    tab: tab,
  );

  void showTab(OverviewPeekTab tab) => state = OverviewFocus(
    selected: state.selected,
    peeked: state.peeked,
    editing: state.editing,
    tab: tab,
    beside: state.beside,
  );

  /// The command is no longer being edited.
  void stopEditing() => state = OverviewFocus(
    selected: state.selected,
    peeked: state.peeked,
    tab: state.tab,
    beside: state.beside,
  );

  void closePeek() => state = OverviewFocus(selected: state.selected);
}

final overviewFocusProvider =
    NotifierProvider.autoDispose<OverviewFocusController, OverviewFocus>(
      OverviewFocusController.new,
    );

/// The branch a reading of [EnvironmentPath] checkout has already named, or
/// null. Borrowed, never asked for, as the Agents lens's rows do.
final overviewKnownBranchProvider = Provider.autoDispose
    .family<String?, EnvironmentPath>((ref, directory) {
      final checkout = Checkout(directory);
      ref.watch(checkoutReadingsProvider.select((r) => r[checkout]));
      final delivery = checkoutDeliveryProvider(checkout);
      if (!ref.exists(delivery)) return null;
      return ref.read(delivery).asData?.value.branch;
    });

/// Where a machine is, as mission control draws it.
enum OverviewMachineKind { local, wsl, ssh }

/// Each known machine's kind, by environment id.
final overviewMachineKindsProvider =
    Provider.autoDispose<Map<String, OverviewMachineKind>>(
      (ref) => {
        for (final environment in ref.watch(environmentsControllerProvider))
          environment.id: switch (environment.kind) {
            EnvironmentKind.wsl => OverviewMachineKind.wsl,
            EnvironmentKind.ssh => OverviewMachineKind.ssh,
            _ => OverviewMachineKind.local,
          },
      },
    );
