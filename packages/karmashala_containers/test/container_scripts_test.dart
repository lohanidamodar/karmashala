import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:test/test.dart';

const _spec = ContainerSpec(
  name: 'sandbox-1',
  distro: ContainerDistro.ubuntu2404,
  cpus: 2,
  memoryMb: 4096,
  agents: [ContainerAgentCli.claude, ContainerAgentCli.gemini],
);

const _key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample karmashala';

void main() {
  group('shellQuote', () {
    test('keeps every character literal', () {
      expect(shellQuote('plain'), "'plain'");
      expect(shellQuote("it's"), r"'it'\''s'");
      expect(
        shellQuote(r'$(rm -rf /) `x` "y" \n'),
        r"""'$(rm -rf /) `x` "y" \n'""",
      );
    });

    test('refuses a variable name it did not make', () {
      expect(() => shellAssign('bad name', 'x'), throwsArgumentError);
      expect(shellAssign('KS_X', "a'b"), r"KS_X='a'\''b'");
    });

    test('a POSIX shell reads a quoted value back exactly', () async {
      const nasty = "a'b \$(echo no) `echo no` \"q\" ; | & \\ * ? \n line2";
      final result = await Process.run('sh', [
        '-c',
        '${shellAssign('V', nasty)}\nprintf %s "\$V"',
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout, nasty);
    }, skip: _hasSh() ? false : 'no sh on this machine');
  });

  group('runContainerScript', () {
    final script = runContainerScript(
      _spec,
      port: 41022,
      publicKeyLine: _key,
      machineId: 'm-1',
    );

    test('binds sshd to the host loopback only', () {
      expect(script, contains("PORT='41022'"));
      expect(script, contains(r'-p "127.0.0.1:$PORT:22"'));
      expect(script, isNot(contains('0.0.0.0')));
    });

    test('names, labels, limits, volume and restart policy', () {
      expect(script, contains("C='ks-sandbox-1'"));
      expect(script, contains('--label dev.karmashala.container=1'));
      expect(script, contains("MACHINE='m-1'"));
      expect(script, contains('--restart unless-stopped'));
      expect(script, contains("CPUS='2'"));
      expect(script, contains("MEMORY='4096m'"));
      expect(script, contains("VOLUME='ks-sandbox-1-home'"));
      expect(script, contains(r'-v "$VOLUME:/home/dev"'));
      expect(script, contains("IMAGE='ubuntu:24.04'"));
    });

    test('passes the key, CLIs and Node minimum as variables', () {
      expect(script, contains("KS_PUBKEY='$_key'"));
      expect(
        script,
        contains("KS_AGENTS='@anthropic-ai/claude-code @google/gemini-cli'"),
      );
      expect(script, contains("KS_NODE_MIN='20'"));
      expect(script, contains(r'-e "KS_PUBKEY=$KS_PUBKEY"'));
    });

    test('refuses to reuse a name already taken', () {
      expect(script, contains(r'if docker inspect "$C"'));
      expect(script, contains('exit 9'));
    });

    test('refuses a multi-line key', () {
      expect(
        () => runContainerScript(
          _spec,
          port: 41022,
          publicKeyLine: '$_key\nmore',
          machineId: 'm',
        ),
        throwsArgumentError,
      );
    });

    test('the whole script parses under sh -n', () async {
      final result = await Process.run('sh', ['-n', '-c', script]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final setup = await Process.run('sh', ['-n', '-c', containerSetupScript]);
      expect(setup.exitCode, 0, reason: '${setup.stderr}');
    }, skip: _hasSh() ? false : 'no sh on this machine');
  });

  group('the setup script', () {
    test('covers apt, dnf, apk and pacman', () {
      for (final pm in ['apt-get', 'dnf', 'apk', 'pacman']) {
        expect(containerSetupScript, contains('$pm)'));
      }
    });

    test('sets up key-only sshd and passwordless sudo once', () {
      expect(containerSetupScript, contains('PasswordAuthentication no'));
      expect(containerSetupScript, contains('PermitRootLogin no'));
      expect(containerSetupScript, contains('NOPASSWD:ALL'));
      expect(containerSetupScript, contains('/etc/karmashala/base-done'));
      expect(containerSetupScript, contains('/etc/karmashala/agents-done'));
    });

    test('falls back to nodejs.org, checksum-verified, when Node is old', () {
      expect(containerSetupScript, contains('nodejs.org/dist/latest-v22.x'));
      expect(containerSetupScript, contains('sha256sum -c'));
    });

    test('reads its parameters from the environment, never its text', () {
      expect(containerSetupScript, contains(r'"$KS_PUBKEY"'));
      expect(containerSetupScript, isNot(contains('ssh-ed25519')));
      expect(containerSetupScript, contains(kReadyMarker));
      expect(containerSetupScript, contains(kFailedMarker));
    });
  });

  group('lifecycle scripts', () {
    test('only touch a prefixed container name', () {
      for (final build in <String Function(String)>[
        containerStatusScript,
        startContainerScript,
        stopContainerScript,
        (name) => deleteContainerScript(name, withHome: false),
        waitForSetupScript,
      ]) {
        expect(() => build('postgres'), throwsArgumentError);
        expect(() => build("ks-x'; rm -rf /"), throwsArgumentError);
        expect(build('ks-sandbox-1'), contains("C='ks-sandbox-1'"));
      }
    });

    test('delete checks the label, and the volume only on request', () {
      final keep = deleteContainerScript('ks-a', withHome: false);
      expect(keep, contains('dev.karmashala.container'));
      expect(keep, contains(r'docker rm -f -v "$C"'));
      expect(keep, contains("WITH_HOME='0'"));
      expect(
        deleteContainerScript('ks-a', withHome: true),
        contains("WITH_HOME='1'"),
      );
    });

    test('status reads as a state', () {
      expect(parseContainerState('running\n'), ContainerState.running);
      expect(parseContainerState('exited'), ContainerState.stopped);
      expect(parseContainerState('missing'), ContainerState.missing);
      expect(parseContainerState('restarting'), ContainerState.starting);
      expect(parseContainerState(''), ContainerState.unknown);
    });

    test('an image reference is checked before it is pulled', () {
      expect(pullImageScript('debian:13'), contains("IMAGE='debian:13'"));
      expect(() => pullImageScript('x; reboot'), throwsArgumentError);
    });
  });

  group('generateContainerKey', () {
    test('makes a usable ed25519 key and its authorized_keys line', () {
      final key = generateContainerKey(
        comment: 'karmashala sandbox-1',
        random: Random(1),
      );
      expect(key.publicLine, startsWith('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5'));
      expect(key.publicLine, endsWith(' karmashala sandbox-1'));
      final parsed = SSHKeyPair.fromPem(key.privatePem).single;
      expect(parsed.type, 'ssh-ed25519');
      expect(key.toString(), isNot(contains('PRIVATE')));
    });

    test('two keys differ', () {
      expect(
        generateContainerKey(comment: 'a').publicLine,
        isNot(generateContainerKey(comment: 'a').publicLine),
      );
    });
  });
}

bool _hasSh() {
  try {
    return Process.runSync('sh', ['-c', 'true']).exitCode == 0;
  } on Object {
    return false;
  }
}
