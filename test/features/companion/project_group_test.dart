/// The partition behind the phone's two screens.
///
/// The invariant the owner reported twice: **the host's order is the order**.
/// Grouping is the one place that could quietly reintroduce a sort, so it is
/// pinned here away from any widget.
library;

import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/presentation/project_group.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  test('projects take their place from their first session, never a sort', () {
    final groups = groupByProject([
      summary('z', title: 'Zebra', project: 'alpha', projectId: 'r1'),
      summary('a', title: 'Apple', project: 'beta', projectId: 'r2'),
      summary('m', title: 'Mango', project: 'alpha', projectId: 'r1'),
    ]);

    expect([for (final g in groups) g.name], ['alpha', 'beta']);
    expect(
      [for (final s in groups.first.sessions) s.title],
      ['Zebra', 'Mango'],
      reason: "inside a project, still the host's order",
    );
  });

  test('a late arrival lands beside its own project, not on the end', () {
    // Exactly what a `session.changed` refresh looks like: the host re-sends
    // its whole list with the newcomer already in place.
    final groups = groupByProject([
      summary('a1', project: 'alpha', projectId: 'r1'),
      summary('a2', project: 'alpha', projectId: 'r1'),
      summary('b1', project: 'beta', projectId: 'r2'),
    ]);

    expect([for (final g in groups) g.name], ['alpha', 'beta']);
    expect([for (final s in groups.first.sessions) s.id], ['a1', 'a2']);
  });

  test('two checkouts sharing a folder name stay two projects', () {
    final groups = groupByProject([
      summary('one', project: 'app', projectId: 'r1'),
      summary('two', project: 'app', projectId: 'r2'),
    ]);
    expect(groups, hasLength(2));
  });

  test('a host too old to send an id falls back to the name', () {
    final groups = groupByProject([
      summary('one', project: 'app'),
      summary('two', project: 'app'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.sessions, hasLength(2));
  });

  test('the summary counts what the host said, and invents nothing', () {
    final groups = groupByProject([
      summary(
        'a',
        project: 'app',
        projectPath: '/w/app',
        status: CompanionSessionStatus.working,
        attention: CompanionAttention(
          kind: CompanionAttentionKind.needsYou,
          at: DateTime.utc(2026),
        ),
      ),
      summary(
        'b',
        project: 'app',
        status: CompanionSessionStatus.idle,
        folderMissing: true,
      ),
    ]);
    final group = groups.single;

    expect(group.path, '/w/app');
    expect(group.summary.sessions, 2);
    expect(group.summary.running, 1);
    expect(group.summary.needsAttention, 1);
    expect(group.summary.label, '2 sessions');
    expect(group.summary.attentionLabel, '1 needs you');
    expect(group.folderMissing, isTrue);
    expect(
      group.summary.changedFiles,
      isNull,
      reason: 'the phone has no git, and must not claim it does',
    );
  });
}
