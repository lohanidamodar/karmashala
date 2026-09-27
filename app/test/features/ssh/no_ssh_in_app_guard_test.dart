import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **The app holds no SSH pool and reads no key** (slice 5d,
/// docs/daemon-architecture.md): the server connects to every box, deploys
/// the Karmashala host there, relays its sessions, sets up its relay and
/// pairs phones — over its own pool, with keys read on its own machine. The
/// app only asks (`features/ssh/data/ssh_client.dart`), keeps what a person
/// decided (`features/ssh/application/`) and shows
/// (`features/ssh/presentation/`).
void main() {
  late Map<String, String> sources;

  setUpAll(() {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'run from the app root');
    sources = {
      for (final file in lib.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart'))
          file.path.replaceAll(r'\', '/').substring('lib/'.length): file
              .readAsStringSync(),
    };
  });

  List<String> filesMatching(RegExp pattern) => [
    for (final entry in sources.entries)
      if (pattern.hasMatch(entry.value)) entry.key,
  ]..sort();

  test('no SSH client, SSH package or the host deployer is imported', () {
    expect(
      filesMatching(
        RegExp(
          r'''import\s+'package:(dartssh2|karmashala_ssh|karmashala_ssh_host)/''',
        ),
      ),
      isEmpty,
    );
  });

  test('no connection, pool, deploy target or box link is built', () {
    expect(
      filesMatching(
        RegExp(
          r'\b(SshConnection|SshConnectionPool|SSHClient|SSHSocket|'
          r'SshHostDeployTarget|HostDeployer|HostInstaller|SshRelaySetup|'
          r'SshCompanionSetup|RemotePairing|BoxLink|SshCommandRunner|'
          r'RemoteFileBrowser)\b',
        ),
      ),
      isEmpty,
    );
  });

  test('no private key is read here', () {
    // A key's path is only ever named (the host dialog's hint, the saved
    // host's field); the server reads it, on its own machine.
    expect(
      filesMatching(
        RegExp(
          r'\b(EnvironmentPrivateKeyReader|readLocalPrivateKey|'
          r'PrivateKeyReader|SSHKeyPair|SSHPem)\b|'
          r'\bFile\([^)]*(\.ssh|privateKey|keyPath)',
        ),
      ),
      isEmpty,
    );
  });

  test('the app\'s SSH feature is presentation, application and one thin '
      'client', () {
    final ssh = [
      for (final path in sources.keys)
        if (path.startsWith('src/features/ssh/')) path,
    ];
    expect(
      ssh.where(
        (path) =>
            !path.startsWith('src/features/ssh/presentation/') &&
            !path.startsWith('src/features/ssh/application/') &&
            !path.startsWith('src/features/ssh/data/'),
      ),
      isEmpty,
    );
    expect(
      [
        for (final path in ssh)
          if (path.startsWith('src/features/ssh/data/')) path,
      ]..sort(),
      [
        'src/features/ssh/data/ssh_client.dart',
        'src/features/ssh/data/ssh_hosts_data.dart',
      ],
    );
  });

  test('application/ is thin: it asks through data/, draws nothing, reads no '
      'file and reaches no transport', () {
    final application = {
      for (final entry in sources.entries)
        if (entry.key.startsWith('src/features/ssh/application/'))
          entry.key: entry.value,
    };
    expect(application, isNotEmpty, reason: 'the guard must see real files');
    final import = RegExp(r"""^import\s+'([^']+)'""", multiLine: true);
    final banned = RegExp(
      r'^(dart:io|package:(dartssh2|karmashala_ssh|karmashala_ssh_host|'
      r'flutter)/|.*/presentation/)',
    );
    final found = <String>[
      for (final entry in application.entries)
        for (final m in import.allMatches(entry.value))
          if (banned.hasMatch(m[1]!) ||
              // Within the feature, only the thin client and the saved hosts.
              (m[1]!.startsWith('../data/') &&
                  m[1] != '../data/ssh_client.dart' &&
                  m[1] != '../data/ssh_hosts_data.dart'))
            '${entry.key}: ${m[1]}',
    ]..sort();
    expect(found, isEmpty);
  });

  test('the app depends on no SSH package', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(
        r'^\s+(dartssh2|karmashala_ssh|karmashala_ssh_host):',
        multiLine: true,
      ).hasMatch(pubspec),
      isFalse,
    );
  });
}
