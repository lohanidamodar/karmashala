import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/cli_detection/application/detected_project_merger.dart';
import 'package:chitragupta/src/features/cli_detection/domain/detected_session.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  final envById = {'windows': windowsEnv(), 'wsl:Ubuntu': wslEnv()};

  DetectedSession sess({
    required String cli,
    required String env,
    required String path,
    String? entrypoint,
    String id = 's',
  }) => DetectedSession(
    cli: cli,
    sessionId: id,
    cwd: EnvironmentPath(environmentId: env, path: path),
    filePath: '/tmp/$id',
    storeHome: '/tmp',
    title: id,
    entrypoint: entrypoint,
    modifiedAt: testTime,
  );

  test('merges the same folder seen via Windows Claude and WSL Codex', () {
    final projects = mergeDetectedProjects([
      sess(
        cli: AgentIds.claudeCode,
        env: 'windows',
        path: r'G:\dev\x',
        id: 'a',
      ),
      sess(
        cli: AgentIds.codex,
        env: 'wsl:Ubuntu',
        path: '/mnt/g/dev/x',
        id: 'b',
      ),
    ], envById);

    expect(projects.length, 1);
    expect(projects.single.sessions.map((s) => s.sessionId).toSet(), {
      'a',
      'b',
    });
    expect(projects.single.countFor(AgentIds.claudeCode), 1);
    expect(projects.single.countFor(AgentIds.codex), 1);
    expect(projects.single.environmentIds, {'windows', 'wsl:Ubuntu'});
  });

  test('SDK-spawned subagents are nested, not top-level', () {
    final projects = mergeDetectedProjects([
      sess(
        cli: AgentIds.claudeCode,
        env: 'windows',
        path: r'G:\dev\x',
        id: 'real',
      ),
      sess(
        cli: AgentIds.claudeCode,
        env: 'windows',
        path: r'G:\dev\x',
        id: 'sub',
        entrypoint: 'sdk-cli',
      ),
    ], envById);

    final project = projects.single;
    expect(project.sessions.map((s) => s.sessionId), ['real']);
    expect(project.subagentSessions.map((s) => s.sessionId), ['sub']);
  });

  test('WSL-native paths stay separate from Windows projects', () {
    final projects = mergeDetectedProjects([
      sess(
        cli: AgentIds.claudeCode,
        env: 'windows',
        path: r'G:\dev\x',
        id: 'a',
      ),
      sess(cli: AgentIds.codex, env: 'wsl:Ubuntu', path: '/home/me/y', id: 'b'),
    ], envById);
    expect(projects.length, 2);
  });

  group('canonicalProjectPath', () {
    test('Windows drive and WSL /mnt fold to the same key', () {
      final (winKey, _) = canonicalProjectPath(
        const EnvironmentPath(environmentId: 'windows', path: r'G:\dev\x'),
        windowsEnv(),
      );
      final (wslKey, _) = canonicalProjectPath(
        const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/mnt/g/dev/x',
        ),
        wslEnv(),
      );
      expect(winKey, wslKey);
    });

    test('WSL-native paths are scoped to the environment', () {
      final (key, display) = canonicalProjectPath(
        const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/y'),
        wslEnv(),
      );
      expect(key, 'wsl:Ubuntu:/home/me/y');
      expect(display, '/home/me/y');
    });
  });
}
