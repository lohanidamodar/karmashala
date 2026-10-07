import 'dart:io';

import 'package:karmashala_ssh_host/src/host_deploy_target.dart';
import 'package:test/test.dart';

/// Every line this package sends is POSIX sh, but sshd runs it in the
/// account's login shell. zsh stops a glob that matches nothing ("no matches
/// found"), so the install listing failed on a zsh account before printing a
/// word. The command is therefore handed to `sh -c` whole.
void main() {
  Future<ProcessResult> viaLoginShell(String shell, String line) =>
      Process.run(shell, ['-c', line]);

  // A Windows shell without Git's tools on its PATH has no `sh`: nothing here
  // can run there, so it says so rather than failing on the missing binary.
  late final bool hasSh;
  setUpAll(() async {
    try {
      hasSh = (await Process.run('sh', ['-c', 'true'])).exitCode == 0;
    } on ProcessException {
      hasSh = false;
    }
  });

  const listing =
      r'''for f in /nonexistent-karmashala/karmashala_host-*; do [ -e "$f" ] || continue; echo "installed=$f"; done; echo 'karmashala-listed' "it's" $((1 + 1))''';

  test(
    'the command reaches sh whole: quotes, dollars and backslashes',
    () async {
      if (!hasSh) return markTestSkipped('no sh on this PATH');
      final result = await viaLoginShell('sh', posixShellCommand(listing));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      // Exactly what sh says for the command given to it directly.
      final direct = await Process.run('sh', ['-c', listing]);
      expect(result.stdout, direct.stdout);
      expect(result.stdout, "karmashala-listed it's 2\n");
    },
  );

  test('a glob matching nothing does not stop it under zsh', () async {
    if (!hasSh) return markTestSkipped('no sh on this PATH');
    final zsh = await Process.run('sh', ['-c', 'command -v zsh']);
    if (zsh.exitCode != 0) {
      markTestSkipped('zsh is not installed here');
      return;
    }
    final bare = await viaLoginShell('zsh', listing);
    expect(
      bare.stdout,
      isNot(contains('karmashala-listed')),
      reason: 'zsh itself refuses the bare loop, which is the bug',
    );
    final wrapped = await viaLoginShell('zsh', posixShellCommand(listing));
    expect(wrapped.stdout, contains('karmashala-listed'));
  });
}
