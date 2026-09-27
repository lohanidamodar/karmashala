import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// **SSH lives in one place in the server** (slice 5d): `lib/src/ssh/`.
/// Every other feature — terminals, launches, worktrees, Flutter runs,
/// automations, files, detection — uses what the ssh domain hands it through
/// its one face, `ssh/ssh_domain.dart` (a runner factory, a file space,
/// sessions on a box, the frame relay), and never dartssh2, the SSH
/// packages, or a file inside the domain's folders.
void main() {
  test('nothing outside lib/src/ssh/ reaches SSH but through '
      'ssh_domain.dart', () {
    final lib = Directory('lib');
    final sshFolder = p.join('lib', 'src', 'ssh');
    final directive = RegExp(
      r'''^(?:import|export)\s+'([^']+)'.*$''',
      multiLine: true,
    );
    final offences = <String>[];
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final path = p.normalize(file.path);
      if (p.isWithin(sshFolder, path)) continue;
      for (final match in directive.allMatches(file.readAsStringSync())) {
        final uri = match[1]!;
        final forbidden =
            uri.startsWith('package:dartssh2/') ||
            uri.startsWith('package:karmashala_ssh/') ||
            uri.startsWith('package:karmashala_ssh_host/') ||
            (!uri.startsWith('package:') &&
                p.isWithin(
                  sshFolder,
                  p.normalize(p.join(p.dirname(path), uri)),
                ) &&
                p.basename(uri) != 'ssh_domain.dart');
        if (forbidden) offences.add('$path: $uri');
      }
    }
    expect(offences, isEmpty);
  });

  test('the ssh domain keeps its own layout: pool, prompts, boxes, deploy '
      'and the requests', () {
    final folders = Directory(p.join('lib', 'src', 'ssh'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toSet();
    expect(
      folders,
      containsAll([
        'pool',
        'prompts',
        'boxes',
        'deploy',
        'ssh_domain.dart',
        'ssh_requests.dart',
      ]),
    );
  });
}
