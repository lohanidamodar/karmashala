import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/explorer_agent_filter.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/application/hidden_working_sessions.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/explorer/application/sub_session_nesting.dart';
import 'package:karmashala/src/features/sessions/application/session_list_prefs.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

class _Live extends LiveAgentStatuses {
  @override
  Map<String, AgentActivityStatus> build() => const {
    'w': AgentActivityStatus.working,
    'w-work': AgentActivityStatus.working,
    'w-ask': AgentActivityStatus.awaitingApproval,
    'w-fail': AgentActivityStatus.failed,
    'n': AgentActivityStatus.working,
    'f': AgentActivityStatus.failed,
    'q': AgentActivityStatus.working,
    's': AgentActivityStatus.working,
    'p-work': AgentActivityStatus.working,
  };

  void set(String id, AgentActivityStatus? status) {
    final next = {...state};
    if (status == null) {
      next.remove(id);
    } else {
      next[id] = status;
    }
    state = Map.unmodifiable(next);
  }
}

/// "Hide while working": a session busy and needing nothing leaves every list
/// until it needs you, its sub-sessions with it, and one line counts them.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  Session row(
    String id, {
    SessionStatus status = SessionStatus.running,
    String? parent,
    DateTime? archivedAt,
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work $id',
    useWorktree: false,
    status: status,
    createdAt: testTime,
    parentSessionId: parent,
    archivedAt: archivedAt,
  );

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows
      ..insert(row('w'))
      ..insert(row('w-ended', status: SessionStatus.completed, parent: 'w'))
      ..insert(row('w-ready', status: SessionStatus.idle, parent: 'w'))
      ..insert(row('w-work', parent: 'w'))
      ..insert(row('w-ask', parent: 'w'))
      ..insert(row('w-fail', parent: 'w'))
      ..insert(
        row(
          'w-old',
          status: SessionStatus.completed,
          parent: 'w',
          archivedAt: testTime,
        ),
      )
      ..insert(row('r', status: SessionStatus.idle))
      ..insert(row('e', status: SessionStatus.completed))
      ..insert(row('n'))
      ..insert(row('f'))
      ..insert(row('q'))
      ..insert(row('s'))
      ..insert(row('p', status: SessionStatus.idle))
      ..insert(row('p-work', parent: 'p'));
    server.sectionRows.put(
      const StoredSection(
        id: 'mine',
        name: 'Mine',
        kind: StoredSection.manualKind,
        position: 0,
        collapsed: false,
        members: {'w', 'w-ended', 'q', 'r'},
      ),
    );
    container = ProviderContainer(
      overrides: [
        await server.override(),
        liveAgentStatusesProvider.overrideWith(_Live.new),
        needsYouProvider.overrideWithValue(const {
          'n': NeedsYouSource(label: 'n', imported: false),
        }),
        onScreenSessionIdProvider.overrideWithValue('s'),
      ],
    );
    addTearDown(container.dispose);
    await pumpEventQueue();
  });

  void hideWorking() =>
      container.read(sessionListPrefsProvider.notifier).setHideWorking(true);

  Set<String> agentsPageIds() => {
    for (final group in container.read(agentStateGroupsProvider))
      for (final entry in group.entries) entry.id,
  };

  test('off by default: nothing is hidden and every list is as it was', () {
    expect(container.read(hideWorkingSessionsProvider), isFalse);
    expect(container.read(hiddenWorkingSessionsProvider).ids, isEmpty);
    expect(agentsPageIds(), containsAll(['w', 'w-work', 'q', 'p-work']));
    final tree = container.read(visibleProjectSessionsProvider('p1'));
    expect(tree.working, 0);
    expect(tree.sessions.native.map((s) => s.id), contains('w'));
  });

  test('working is hidden; needs-you, failed, ready, ended and the session '
      'on screen are not; a hidden parent takes its quiet children', () {
    hideWorking();
    final hidden = container.read(hiddenWorkingSessionsProvider);
    expect(
      hidden.ids,
      unorderedEquals([
        'w',
        'w-ended',
        'w-ready',
        'w-work',
        'w-old',
        'q',
        'p-work',
      ]),
    );
    expect(hidden.topLevel, unorderedEquals(['w', 'q', 'p-work']));
    for (final shown in ['w-ask', 'w-fail', 'r', 'e', 'n', 'f', 's', 'p']) {
      expect(hidden.ids, isNot(contains(shown)), reason: shown);
    }
  });

  test('the Agents page drops them, and a needs-you child of a hidden parent '
      'stands at the top level', () {
    hideWorking();
    final sub = container.listen(agentStateGroupsProvider, (_, _) {});
    addTearDown(sub.close);
    final shown = agentsPageIds();
    expect(shown, isNot(contains('w')));
    expect(shown, isNot(contains('w-work')));
    expect(shown, containsAll(['w-ask', 'w-fail', 's', 'n', 'r', 'e']));
    final nesting = SubSessionNesting.of(sub.read());
    final needsYou = nesting.groups.firstWhere(
      (g) => g.state == AgentState.needsYou,
    );
    expect(needsYou.entries.map((e) => e.id), contains('w-ask'));
    expect(container.read(agentsHiddenWorkingCountProvider), 3);
  });

  test('the project tree drops them and counts each hidden lineage once', () {
    hideWorking();
    final tree = container.read(visibleProjectSessionsProvider('p1'));
    final ids = tree.sessions.native.map((s) => s.id).toSet();
    expect(ids, isNot(contains('w')));
    expect(ids, isNot(contains('w-ready')));
    expect(ids, containsAll(['w-ask', 'w-fail', 's', 'p']));
    expect(tree.working, 3);
  });

  test('a section drops them and counts the top-level ones', () {
    hideWorking();
    final sub = container.listen(
      explorerSectionMembersProvider('mine'),
      (_, _) {},
    );
    addTearDown(sub.close);
    expect(sub.read().map((f) => f.id), ['r']);
    expect(container.read(explorerSectionHiddenWorkingProvider('mine')), 2);
  });

  test('a session that leaves working is back in the same read, no timer', () {
    hideWorking();
    final sub = container.listen(agentStateGroupsProvider, (_, _) {});
    addTearDown(sub.close);
    expect(agentsPageIds(), isNot(contains('w')));

    final live = container.read(liveAgentStatusesProvider.notifier) as _Live;
    live.set('w', null);
    expect(agentsPageIds(), containsAll(['w', 'w-ready', 'w-ended']));
    // Its own working child is hidden now in its own right.
    expect(agentsPageIds(), isNot(contains('w-work')));

    live.set('q', AgentActivityStatus.awaitingApproval);
    expect(agentsPageIds(), contains('q'));
    live.set('p-work', AgentActivityStatus.failed);
    expect(agentsPageIds(), contains('p-work'));
  });

  test('the switch is kept per device, across a reload of its file', () async {
    final dir = await Directory.systemTemp.createTemp('ks-hide-working');
    addTearDown(() => dir.delete(recursive: true));
    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [
          sessionListPrefsDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    final first = open();
    first.read(sessionListPrefsProvider.notifier).setHideWorking(true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}sessions_device.json',
    );
    for (var i = 0; i < 100 && !file.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(jsonDecode(file.readAsStringSync())['hideWorking'], isTrue);

    final second = open();
    second.read(sessionListPrefsProvider);
    for (var i = 0; i < 100 && !second.read(hideWorkingSessionsProvider); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(second.read(hideWorkingSessionsProvider), isTrue);
  });
}
