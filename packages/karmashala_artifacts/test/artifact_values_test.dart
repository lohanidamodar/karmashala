import 'package:agent_cli/process.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 10, 6, 9);
  Artifact sample() => Artifact(
    id: 'a1',
    sessionId: 's1',
    title: 'Coverage',
    kind: ArtifactKind.html,
    mode: ArtifactMode.wide,
    origin: ArtifactOrigin.tool,
    source: const EnvironmentPath(
      environmentId: 'local',
      path: '/home/me/report.html',
    ),
    fileName: 'report.html',
    revision: 2,
    size: 120,
    mimeType: 'text/html',
    createdAt: at,
    updatedAt: at,
  );

  test('a client copy round-trips everything but the source path', () {
    final json = artifactToClientJson(sample());
    expect(json.toString(), isNot(contains('/home/me')));
    final back = artifactFromJson(json);
    expect(back.id, 'a1');
    expect(back.kind, ArtifactKind.html);
    expect(back.mode, ArtifactMode.wide);
    expect(back.revision, 2);
    expect(back.fileName, 'report.html');
    expect(back.source, isNull);
    expect(back.hasSource, isTrue);
    expect(back.createdAt, at);
    expect(back.networkAllowed, isFalse);
    expect(back.sourceState, ArtifactSourceState.present);
  });

  test('a kind is inferred from the file name', () {
    expect(artifactKindForName('x.html'), ArtifactKind.html);
    expect(artifactKindForName('x.HTM'), ArtifactKind.html);
    expect(artifactKindForName('x.svg'), ArtifactKind.svg);
    expect(artifactKindForName('flow.mmd'), ArtifactKind.mermaid);
    expect(artifactKindForName('flow.mermaid'), ArtifactKind.mermaid);
    expect(artifactKindForName('notes.md'), ArtifactKind.markdown);
    expect(artifactKindForName('shot.png'), ArtifactKind.image);
    expect(artifactKindForName('shot.jpeg'), ArtifactKind.image);
    expect(artifactKindForName('paper.pdf'), ArtifactKind.pdf);
    expect(artifactKindForName('data.bin'), isNull);
  });

  test('a kind or mode is read by name, null when unknown', () {
    expect(ArtifactKind.parse('svg'), ArtifactKind.svg);
    expect(ArtifactKind.parse('video'), isNull);
    expect(ArtifactMode.parse('wide'), ArtifactMode.wide);
    expect(ArtifactMode.parse('huge'), isNull);
  });

  test('an unknown kind on the wire is refused, not guessed', () {
    final json = artifactToClientJson(sample())..['kind'] = 'video';
    expect(() => artifactFromJson(json), throwsFormatException);
  });
}
