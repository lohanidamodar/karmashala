import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

/// **Which rows the user folded away, remembered.**
///
/// The spine is the machine now and there is no toggle, so what has to survive
/// a restart is the folding: a tree that springs open every launch is worse
/// than one that never folds. Absence means expanded, deliberately — a machine
/// added tomorrow opens rather than inheriting somebody else's fold.
void main() {
  test('nothing is folded away until somebody folds it', () {
    expect(const Settings().collapsedExplorerNodes, isEmpty);
  });

  test('the folds survive being written and read back', () {
    const chosen = Settings(
      collapsedExplorerNodes: ['env:windows', 'env:ssh:h1/ctx:c1'],
    );

    expect(Settings.fromJson(chosen.toJson()).collapsedExplorerNodes, [
      'env:windows',
      'env:ssh:h1/ctx:c1',
    ]);
  });

  test('settings written before this existed read as nothing folded', () {
    final old = Settings().toJson()..remove('collapsedExplorerNodes');

    expect(Settings.fromJson(old).collapsedExplorerNodes, isEmpty);
  });

  test('the spine is no longer a stored choice', () {
    // v1.22 and earlier carried `explorerGroupByEnvironment`. It is ignored
    // rather than migrated: there is one spine now, and a restored `false`
    // would ask for a layout that no longer exists.
    final old = Settings().toJson()..['explorerGroupByEnvironment'] = false;

    expect(Settings.fromJson(old).collapsedExplorerNodes, isEmpty);
  });
}
