import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/workspace_session_entry.dart';
import 'package:karmashala_session/session.dart';

import '../../support/fixtures.dart';

/// **The Agents page's grouping, without a widget.** Every session lands in
/// exactly one of five states, in one order, from facts the app already holds.
void main() {
  WorkspaceSessionEntry native(
    String id, {
    SessionStatus status = SessionStatus.idle,
    DateTime? lastActive,
    bool archived = false,
  }) => WorkspaceSessionEntry(
    id: id,
    title: id,
    createdAt: testTime,
    lastActiveAt: lastActive,
    native: session(
      id: id,
      status: status,
    ).copyWith(archivedAt: archived ? testTime : null),
  );

  WorkspaceSessionEntry imported(String id, {DateTime? lastActive}) =>
      WorkspaceSessionEntry(
        id: id,
        title: id,
        createdAt: testTime,
        lastActiveAt: lastActive,
        imported: ImportedSession(
          id: id,
          repositoryId: 'r1',
          cli: AgentIds.claudeCode,
          externalId: 'ext-$id',
          environmentId: 'windows',
          filePath: '/x/$id.jsonl',
          storeHome: '/x',
          isSubagent: false,
          preview: '',
          createdAt: testTime,
        ),
      );

  group('agentStateOf', () {
    test('waiting outranks every other fact, from either source', () {
      for (final row in SessionStatus.values) {
        expect(
          agentStateOf(
            needsYou: true,
            live: AgentActivityStatus.working,
            rowStatus: row,
          ),
          AgentState.needsYou,
        );
        expect(
          agentStateOf(
            needsYou: false,
            live: AgentActivityStatus.awaitingApproval,
            rowStatus: row,
          ),
          AgentState.needsYou,
        );
      }
    });

    test('a live status outranks the recorded lifecycle', () {
      expect(
        agentStateOf(
          needsYou: false,
          live: AgentActivityStatus.working,
          rowStatus: SessionStatus.completed,
        ),
        AgentState.working,
      );
      expect(
        agentStateOf(
          needsYou: false,
          live: AgentActivityStatus.failed,
          rowStatus: SessionStatus.running,
        ),
        AgentState.failed,
      );
    });

    test('with nothing live, the record decides Ready or Ended', () {
      final expected = {
        SessionStatus.created: AgentState.ready,
        SessionStatus.running: AgentState.ready,
        SessionStatus.idle: AgentState.ready,
        SessionStatus.unknown: AgentState.ended,
        SessionStatus.completed: AgentState.ended,
        SessionStatus.failed: AgentState.ended,
        SessionStatus.cancelled: AgentState.ended,
      };
      for (final MapEntry(key: row, value: state) in expected.entries) {
        for (final live in [
          null,
          AgentActivityStatus.idle,
          AgentActivityStatus.unknown,
        ]) {
          expect(
            agentStateOf(needsYou: false, live: live, rowStatus: row),
            state,
            reason: '$row with live $live',
          );
        }
      }
    });

    test('a completed row whose agent reads idle is Ended, as the app reports '
        'it — the /clear bug is not papered over here', () {
      expect(
        agentStateOf(
          needsYou: false,
          live: AgentActivityStatus.idle,
          rowStatus: SessionStatus.completed,
        ),
        AgentState.ended,
      );
    });

    test('an archived row and an imported conversation are Ended', () {
      expect(
        agentStateOf(
          needsYou: false,
          live: null,
          rowStatus: SessionStatus.running,
          archived: true,
        ),
        AgentState.ended,
      );
      expect(
        agentStateOf(needsYou: false, live: null, rowStatus: null),
        AgentState.ended,
      );
      expect(
        agentStateOf(
          needsYou: false,
          live: AgentActivityStatus.working,
          rowStatus: null,
        ),
        AgentState.working,
        reason: 'an imported conversation observed in a turn is working',
      );
    });
  });

  group('groupByAgentState', () {
    test('always five groups, in the order the page draws them', () {
      final groups = groupByAgentState(const [], needsYou: {}, live: {});
      expect(
        [for (final g in groups) g.state],
        [
          AgentState.needsYou,
          AgentState.working,
          AgentState.failed,
          AgentState.ready,
          AgentState.ended,
        ],
      );
      expect(groups.every((g) => g.isEmpty), isTrue);
      expect(
        [for (final g in groups) g.state.label],
        ['Needs you', 'Working', 'Failed', 'Ready', 'Ended'],
      );
    });

    test('each session lands in exactly one group', () {
      final entries = [
        native('waiting'),
        native('asking', status: SessionStatus.running),
        native('busy'),
        native('broken'),
        native('open'),
        native('done', status: SessionStatus.completed),
        imported('history'),
      ];
      final groups = groupByAgentState(
        entries,
        needsYou: {
          'waiting': const NeedsYouSource(label: 'waiting', imported: false),
        },
        live: {
          'asking': AgentActivityStatus.awaitingApproval,
          'busy': AgentActivityStatus.working,
          'broken': AgentActivityStatus.failed,
        },
      );
      Map<AgentState, List<String>> ids() => {
        for (final g in groups) g.state: [for (final e in g.entries) e.id],
      };
      expect(ids(), {
        AgentState.needsYou: unorderedEquals(['waiting', 'asking']),
        AgentState.working: ['busy'],
        AgentState.failed: ['broken'],
        AgentState.ready: ['open'],
        AgentState.ended: unorderedEquals(['done', 'history']),
      });
      final total = groups.fold<int>(0, (n, g) => n + g.length);
      expect(total, entries.length);
    });

    test('a session listed twice is drawn once', () {
      final groups = groupByAgentState(
        [native('a'), native('a')],
        needsYou: {},
        live: {},
      );
      expect(groups.fold<int>(0, (n, g) => n + g.length), 1);
    });

    test('a waiting session with no row is still in Needs you, so the group '
        'is exactly as long as the count', () {
      final needsYou = {
        'gone': const NeedsYouSource(label: 'Deleted chat', imported: false),
        'here': const NeedsYouSource(label: 'here', imported: false),
      };
      final groups = groupByAgentState(
        [native('here')],
        needsYou: needsYou,
        live: {},
      );
      final waiting = groups.first;
      expect(waiting.length, needsYou.length);
      expect(waiting.entries.map((e) => e.title), contains('Deleted chat'));
    });

    test('newest activity first, the created date standing in when nothing '
        'was observed, and the id breaking a tie', () {
      final groups = groupByAgentState(
        [
          native('old', lastActive: testTime.add(const Duration(minutes: 1))),
          native('new', lastActive: testTime.add(const Duration(hours: 1))),
          native('unseen-b'),
          native('unseen-a'),
        ],
        needsYou: {},
        live: {},
      );
      expect(
        [for (final e in groups[AgentState.ready.index].entries) e.id],
        ['new', 'old', 'unseen-a', 'unseen-b'],
      );
    });
  });

  group('the fold', () {
    AgentStateGroup group(AgentState state, int n) =>
        AgentStateGroup(state, [for (var i = 0; i < n; i++) native('s$i')]);

    test('Needs you, Working and Failed are always whole', () {
      for (final state in [
        AgentState.needsYou,
        AgentState.working,
        AgentState.failed,
      ]) {
        expect(visibleRowCount(group(state, 30), expanded: false), 30);
      }
    });

    test('Ready shows eight, then folds; opened, all of it', () {
      expect(kReadyVisibleRows, 8);
      expect(visibleRowCount(group(AgentState.ready, 5), expanded: false), 5);
      expect(visibleRowCount(group(AgentState.ready, 8), expanded: false), 8);
      expect(visibleRowCount(group(AgentState.ready, 20), expanded: false), 8);
      expect(visibleRowCount(group(AgentState.ready, 20), expanded: true), 20);
    });

    test('Ended starts folded', () {
      expect(visibleRowCount(group(AgentState.ended, 12), expanded: false), 0);
      expect(visibleRowCount(group(AgentState.ended, 12), expanded: true), 12);
    });
  });

  group('sessionContextClauses', () {
    test('project, then folder only when it differs, then branch', () {
      expect(
        sessionContextClauses(
          projectName: 'Karmashala',
          folder: 'karmashala-app',
          branch: 'main',
        ),
        ['Karmashala', 'karmashala-app', 'main'],
      );
    });

    test('a folder that is the project name again is left out, whatever its '
        'case', () {
      expect(sessionContextClauses(projectName: 'Realm', folder: 'realm'), [
        'Realm',
      ]);
    });

    test('a branch nobody has read is not named', () {
      expect(
        sessionContextClauses(projectName: 'A', folder: 'b', branch: null),
        ['A', 'b'],
      );
      expect(sessionContextClauses(branch: '  '), isEmpty);
    });

    test(
      'the folder is the last segment of the directory, either separator',
      () {
        WorkspaceSessionEntry at(String path) => WorkspaceSessionEntry(
          id: 'x',
          title: 'x',
          createdAt: testTime,
          directory: EnvironmentPath(environmentId: 'windows', path: path),
        );
        expect(at(r'C:\src\wt\feature-a\').folder, 'feature-a');
        expect(at('/home/me/app').folder, 'app');
        expect(
          WorkspaceSessionEntry(
            id: 'x',
            title: 'x',
            createdAt: testTime,
          ).folder,
          isNull,
        );
      },
    );
  });
}
