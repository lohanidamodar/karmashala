import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_snippets/karmashala_snippets.dart';
import 'package:test/test.dart';

/// The git side tables, snippets and presets through the envelope as JSON.
void main() {
  final t0 = DateTime.utc(2026, 9, 27, 9, 30);
  const setup = WorktreeSetup(
    command: ['flutter', 'pub', 'get'],
    copyPaths: ['.env.local'],
    startAgentBeforeSetup: false,
    teardown: ['docker', 'compose', 'down'],
  );
  final report = WorktreeSetupReport(
    repositoryId: 'r1',
    worktreePath: '/w/one',
    environmentId: 'windows',
    ranAt: t0,
    copies: const [
      WorktreeCopyVerdict(
        path: '.env.local',
        result: WorktreeCopyResult.copied,
        reason: '',
      ),
    ],
  );
  const anchor = ReviewAnchor(
    path: 'lib/a.dart',
    blobSha: 'abc',
    startLine: 3,
    endLine: 4,
    excerpt: 'x',
  );
  final thread = ReviewThread(
    id: 't1',
    repositoryId: 'r1',
    anchor: anchor,
    status: ReviewThreadStatus.shouldFix,
    sessionId: 's1',
    createdAt: t0,
    updatedAt: t0,
    comments: [
      ReviewComment(
        id: 7,
        threadId: 't1',
        sequence: 1,
        author: 'me',
        authorKind: ReviewAuthorKind.user,
        body: 'fix',
        createdAt: t0,
      ),
    ],
  );
  final snippet = CommandSnippet(
    id: 's1',
    label: 'build',
    command: 'make',
    shellId: 'wsl',
    submit: true,
    createdAt: t0,
    updatedAt: t0,
  );
  final preset = StoredPreset(
    id: 'p1',
    name: 'two panes',
    shape: const {
      'tabs': [
        {'x': 1},
      ],
      'active': 0,
    },
    updatedAt: t0,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const WorktreesList(),
      const WorktreeSetupSave('r1', setup),
      const WorktreeSetupClear('r1'),
      WorktreeSetupRecord(report),
      const ReviewThreadOpen(
        id: 't1',
        repositoryId: 'r1',
        anchor: anchor,
        author: 'me',
        authorKind: ReviewAuthorKind.agent,
        body: 'b',
        status: ReviewThreadStatus.open,
        sessionId: 's1',
      ),
      const ReviewThreadReply(
        threadId: 't1',
        author: 'me',
        authorKind: ReviewAuthorKind.user,
        body: 'r',
      ),
      const ReviewThreadSetStatus('t1', ReviewThreadStatus.resolved),
      const SnippetsList(),
      const SnippetAdd(id: 's1', label: 'l', command: 'c', shellId: 'wsl'),
      const SnippetEdit(id: 's1', label: 'l', command: 'c', submit: true),
      const SnippetDelete('s1'),
      PresetSave(id: 'p1', presetName: 'n', shape: preset.shape),
      const PresetDelete('p1'),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('answers carry typed results', () {
    DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
        DataEnvelope.readAnswer(
          overTheWire(
            DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
          ),
          request,
        );

    final list = roundTrip(
      const WorktreesList(),
      WorktreesSnapshot(
        setups: const {'r1': setup},
        runs: [report],
        threads: [thread],
      ),
    ).value;
    expect(list.setups['r1'], setup);
    expect(sameSetupReport(list.runs.single, report), isTrue);
    expect(list.runs.single.verdict, report.verdict);
    final read = list.threads.single;
    expect(sameReviewThread(read, thread), isTrue);
    expect(read.anchor.location, 'lib/a.dart:3-4');
    expect(read.comments.single.body, 'fix');
    expect(read.sessionId, 's1');

    final snippets = roundTrip(
      const SnippetsList(),
      SnippetsSnapshot(snippets: [snippet], presets: [preset]),
    ).value;
    expect(snippets.snippets.single, snippet);
    expect(snippets.presets.single, preset);
  });

  test('every change round-trips', () {
    final changes = <DataChange>[
      const WorktreeSetupChanged('r1', setup),
      const WorktreeSetupChanged('r1', null),
      WorktreeRunRecorded(report),
      ReviewThreadChanged(thread),
      WorktreeRunRemoved(report.key),
      const ReviewThreadRemoved('t1'),
      SnippetChanged(snippet),
      const SnippetRemoved('s1'),
      PresetChanged(preset),
      const PresetRemoved('p1'),
    ];
    final read = DataChanges.fromJson(
      overTheWire(DataChanges(5, changes).toJson()),
    );
    expect([for (final c in read.changes) c.toJson()], [
      for (final c in changes) overTheWire(c.toJson()),
    ]);
  });

  test('an unknown kind is refused', () {
    final read = DataEnvelope.readRequest(
      overTheWire({'id': 1, 'kind': 'snippets.nope', 'arguments': {}}),
    );
    expect(read.refusal!.code, DataRefusalCode.invalid);
  });
}
