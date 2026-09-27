import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:test/test.dart';

/// `readCheckoutLabels`: worktree-or-not, branch and owner of every recorded
/// checkout, from one `git worktree list` per repository family.
void main() {
  final created = DateTime.utc(2026);

  Repository row(String id, String path, {String env = 'local'}) => Repository(
    id: id,
    projectId: 'p1',
    name: id,
    path: EnvironmentPath(environmentId: env, path: path),
    createdAt: created,
  );

  GitWorktree listed(String path, {String? branch, String env = 'local'}) =>
      GitWorktree(
        path: EnvironmentPath(environmentId: env, path: path),
        branch: branch,
      );

  final main = row('main', '/src/app');
  final wt1 = row('wt1', '/src/.karmashala-worktrees/app-a');
  final wt2 = row('wt2', '/src/.karmashala-worktrees/app-b');
  final family = [
    listed('/src/app', branch: 'main'),
    listed('/src/.karmashala-worktrees/app-a', branch: 'session/a'),
    listed('/src/.karmashala-worktrees/app-b'),
  ];

  test('one listing labels the whole family, owner and branch', () async {
    final asked = <String>[];
    final labels = await readCheckoutLabels([main, wt1, wt2], (path) async {
      asked.add(path.path);
      return family;
    });
    expect(asked, ['/src/app'], reason: 'the family is asked once');
    expect(labels['main'], const CheckoutLabel(isWorktree: false, branch: 'main'));
    expect(
      labels['wt1'],
      const CheckoutLabel(
        isWorktree: true,
        branch: 'session/a',
        ownerRepositoryId: 'main',
      ),
    );
    expect(labels['wt2']!.branch, isNull, reason: 'detached');
    expect(labels['wt2']!.ownerRepositoryId, 'main');
  });

  test('a family key asks each family once, all together', () async {
    final other = row('other', '/src/other');
    final asked = <String>[];
    final labels = await readCheckoutLabels(
      [wt1, main, other, wt2],
      (path) async {
        asked.add(path.path);
        return path.path == '/src/other'
            ? [listed('/src/other', branch: 'dev')]
            : family;
      },
      familyKey: (path) async =>
          path.path == '/src/other' ? 'other.git' : 'app.git',
    );
    expect(asked, unorderedEquals(['/src/.karmashala-worktrees/app-a', '/src/other']));
    expect(labels.keys, containsAll(['main', 'wt1', 'wt2', 'other']));
    expect(labels['other']!.isWorktree, isFalse);
  });

  test('a checkout whose git could not answer is absent, not wrong', () async {
    final labels = await readCheckoutLabels([main, row('ssh', '/x', env: 'ssh:h')], (
      path,
    ) async {
      if (path.environmentId == 'ssh:h') throw GitException('no route');
      return family;
    }, familyKey: (path) async => throw StateError('no key'));
    expect(labels.containsKey('ssh'), isFalse);
    expect(labels['main']!.isWorktree, isFalse);
  });

  test('a main checkout nobody recorded leaves its worktree without owner', () async {
    final labels = await readCheckoutLabels([wt1], (_) async => family);
    expect(labels['wt1']!.isWorktree, isTrue);
    expect(labels['wt1']!.ownerRepositoryId, isNull);
  });

  test('a label survives its JSON', () {
    const label = CheckoutLabel(
      isWorktree: true,
      branch: 'b',
      ownerRepositoryId: 'o',
    );
    expect(CheckoutLabel.fromJson(label.toJson()), label);
    expect(
      CheckoutLabel.fromJson(const CheckoutLabel(isWorktree: false).toJson()),
      const CheckoutLabel(isWorktree: false),
    );
  });
}
