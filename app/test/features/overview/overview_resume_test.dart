import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_resume.dart';

/// **What Resume… lists, narrowed**: archived sessions only on request, one
/// project or agent at a time, and every word of the search somewhere in
/// the title, agent, model or project.
void main() {
  final at = DateTime.utc(2026, 10, 7);
  final candidates = [
    ResumeCandidate(
      id: 'a',
      title: 'Round 30 webhooks',
      lastActiveAt: at,
      agentId: 'claude-code',
      agentName: 'Claude Code',
      modelId: 'claude-opus-5-5',
      projectId: 'p-ks',
      projectName: 'karmashala',
    ),
    ResumeCandidate(
      id: 'b',
      title: 'Scaffold templates',
      lastActiveAt: at,
      agentId: 'codex',
      agentName: 'Codex',
      projectId: 'p-beej',
      projectName: 'beej',
    ),
    ResumeCandidate(
      id: 'c',
      title: 'Old port',
      lastActiveAt: at,
      agentId: 'codex',
      agentName: 'Codex',
      projectId: 'p-ks',
      projectName: 'karmashala',
      archived: true,
    ),
  ];

  List<String> ids(List<ResumeCandidate> shown) => [
    for (final c in shown) c.id,
  ];

  test('archived ones only when asked for', () {
    expect(ids(filterResumeCandidates(candidates)), ['a', 'b']);
    expect(ids(filterResumeCandidates(candidates, includeArchived: true)), [
      'a',
      'b',
      'c',
    ]);
  });

  test('by project and by agent', () {
    expect(
      ids(
        filterResumeCandidates(
          candidates,
          projectId: 'p-ks',
          includeArchived: true,
        ),
      ),
      ['a', 'c'],
    );
    expect(ids(filterResumeCandidates(candidates, agentId: 'codex')), ['b']);
  });

  test('every word of the search, in any field, any case', () {
    expect(ids(filterResumeCandidates(candidates, query: 'OPUS hooks')), ['a']);
    expect(ids(filterResumeCandidates(candidates, query: 'beej')), ['b']);
    expect(filterResumeCandidates(candidates, query: 'codex opus'), isEmpty);
  });
}
