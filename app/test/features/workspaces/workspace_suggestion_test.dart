import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala/src/features/workspaces/application/workspace_suggestion.dart';

import '../../support/fixtures.dart';

void main() {
  Project filed(
    String id,
    String path, {
    String? workspaceId,
    String environmentId = 'windows',
  }) => Project(
    id: id,
    name: id,
    root: EnvironmentPath(environmentId: environmentId, path: path),
    createdAt: testTime,
    workspaceId: workspaceId,
  );

  String? suggest(
    String path, {
    required List<Project> projects,
    String environmentId = 'windows',
  }) => suggestWorkspaceForRoot(
    root: EnvironmentPath(environmentId: environmentId, path: path),
    projects: projects,
  );

  group('on Windows roots', () {
    // The owner's own layout: games under one folder, PopupBits under another,
    // both under `C:\Users\dlohani\projects`.
    final workspace = [
      filed(
        'g1',
        r'C:\Users\dlohani\projects\games\roguelike',
        workspaceId: 'games',
      ),
      filed(
        'g2',
        r'C:\Users\dlohani\projects\games\platformer',
        workspaceId: 'games',
      ),
      filed(
        'pb1',
        r'C:\Users\dlohani\projects\popupbits\projects\karmashala',
        workspaceId: 'popupbits',
      ),
    ];

    test('a new game is suggested the games context', () {
      expect(
        suggest(r'C:\Users\dlohani\projects\games\shmup', projects: workspace),
        'games',
      );
    });

    test('a new PopupBits app is suggested PopupBits', () {
      expect(
        suggest(
          r'C:\Users\dlohani\projects\popupbits\projects\meronepali',
          projects: workspace,
        ),
        'popupbits',
      );
    });

    test('a tie suggests nothing', () {
      // `…\projects\other` is as much PopupBits as it is games. That is a
      // question, not an answer.
      expect(
        suggest(r'C:\Users\dlohani\projects\other', projects: workspace),
        isNull,
      );
    });

    test('separators and case do not decide it', () {
      expect(
        suggest('c:/USERS/Dlohani/projects/games/shmup/', projects: workspace),
        'games',
      );
    });

    test('a lone shared drive is not evidence', () {
      expect(suggest(r'D:\elsewhere\thing', projects: workspace), isNull);
      expect(
        suggest(
          r'C:\somewhere\else',
          projects: [
            filed(
              'only',
              r'C:\Users\dlohani\projects\games\rl',
              workspaceId: 'games',
            ),
          ],
        ),
        isNull,
        reason: 'sharing only the drive says nothing',
      );
    });

    test('unassigned projects vote for nothing', () {
      expect(
        suggest(
          r'C:\Users\dlohani\projects\games\shmup',
          projects: [filed('g1', r'C:\Users\dlohani\projects\games\roguelike')],
        ),
        isNull,
      );
    });

    test('an empty workspace suggests nothing', () {
      expect(
        suggest(r'C:\Users\dlohani\projects\games\x', projects: const []),
        isNull,
      );
    });
  });

  group('across namespaces', () {
    test('a WSL root is not matched against Windows projects', () {
      // `/mnt/c/Users/dlohani/projects/games/x` and
      // `C:\Users\dlohani\projects\games\x` are the same folder, and the app
      // stores them as different environments. Guessing across the boundary
      // would file a WSL project by a Windows sibling's spelling.
      expect(
        suggest(
          '/mnt/c/Users/dlohani/projects/games/shmup',
          environmentId: 'wsl:Ubuntu',
          projects: [
            filed(
              'g1',
              r'C:\Users\dlohani\projects\games\roguelike',
              workspaceId: 'games',
            ),
          ],
        ),
        isNull,
      );
    });

    test('WSL roots match other WSL roots, POSIX-style', () {
      expect(
        suggest(
          '/home/dlohani/projects/games/shmup',
          environmentId: 'wsl:Ubuntu',
          projects: [
            filed(
              'g1',
              '/home/dlohani/projects/games/roguelike',
              environmentId: 'wsl:Ubuntu',
              workspaceId: 'games',
            ),
            filed(
              'pb',
              '/home/dlohani/popupbits/karmashala',
              environmentId: 'wsl:Ubuntu',
              workspaceId: 'popupbits',
            ),
          ],
        ),
        'games',
      );
    });

    test('an SSH root behaves like any other POSIX root', () {
      expect(
        suggest(
          '/srv/build/appwrite/functions',
          environmentId: 'ssh:build-box',
          projects: [
            filed(
              'a1',
              '/srv/build/appwrite/console',
              environmentId: 'ssh:build-box',
              workspaceId: 'appwrite',
            ),
          ],
        ),
        'appwrite',
      );
    });

    test('POSIX paths keep their case', () {
      expect(
        suggest(
          '/home/dlohani/Projects/games/shmup',
          environmentId: 'wsl:Ubuntu',
          projects: [
            filed(
              'g1',
              '/home/dlohani/projects/games/roguelike',
              environmentId: 'wsl:Ubuntu',
              workspaceId: 'games',
            ),
          ],
        ),
        isNull,
        reason: '/home/dlohani is three segments of agreement, below the bar',
      );
    });
  });

  test('a blank root suggests nothing', () {
    expect(suggest('   ', projects: const []), isNull);
  });
}
