import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/agents/acp_binary_installer.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';

/// The installer over a fake runner: which scripts reach which shell, what
/// they do, what the answer is, and what is refused before anything runs.
/// Nothing here downloads.
void main() {
  final t0 = DateTime.utc(2026, 10, 2);
  final wsl = ExecutionEnvironment(
    id: 'wsl:arch',
    kind: EnvironmentKind.wsl,
    name: 'archlinux',
    wslDistribution: 'archlinux',
    createdAt: t0,
  );
  final windows = ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: t0,
  );
  final ssh = ExecutionEnvironment(
    id: 'ssh:box',
    kind: EnvironmentKind.ssh,
    name: 'box',
    sshHostId: 'h1',
    createdAt: t0,
  );

  const linux = AcpAgentInstall(
    environmentId: 'wsl:arch',
    registryId: 'antigravity-acp',
    version: '1.3.0',
    archive:
        'https://dl.example.test/releases/linux/agy-acp-server-1.3.0-linux-x86_64.zip',
    command: './agy_acp_server.par',
    args: ['--uid='],
    agentId: 'antigravity-acp',
  );

  CommandResult ok(String stdout) =>
      CommandResult(exitCode: 0, stdout: stdout, stderr: '');

  Matcher refused(DataRefusalCode code, String words) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words)),
  );

  test('on POSIX: two scripts on bash\'s stdin, the path answered', () async {
    final runner = FakeCommandRunner(
      environmentId: wsl.id,
      responder: (req) => req.stdinText!.contains('printf')
          ? ok(
              '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par\n',
            )
          : ok(''),
    );
    final steps = <AcpInstallStep>[];
    final path = await AcpBinaryInstaller(
      runnerFor: (_) => runner,
    ).install(wsl, linux, onStep: steps.add);

    expect(
      path,
      '/home/me/karmashala/acp/antigravity-acp/1.3.0/agy_acp_server.par',
    );
    expect(steps, [AcpInstallStep.downloading, AcpInstallStep.unpacking]);
    expect(runner.requests, hasLength(2));
    for (final request in runner.requests) {
      expect(request.executable, 'bash');
      expect(request.arguments, ['-ls']);
      expect(request.timeout, const Duration(minutes: 20));
      expect(
        request.stdinText,
        contains('dir="\$HOME/karmashala/acp/antigravity-acp/1.3.0"'),
      );
    }
    final download = runner.requests[0].stdinText!;
    expect(download, contains('mkdir -p "\$dir"'));
    expect(
      download,
      contains(
        'curl -fsSL -o "\$dir/agy-acp-server-1.3.0-linux-x86_64.zip" '
        "'${linux.archive}'",
      ),
    );
    expect(download, contains('wget -q -O'));
    final unpack = runner.requests[1].stdinText!;
    expect(unpack, contains('unzip -o -q "\$archive" -d "\$dir"'));
    expect(unpack, contains('python3 -m zipfile -e "\$archive" "\$dir"'));
    expect(unpack, contains('rm -f "\$archive"'));
    expect(unpack, contains('chmod +x "\$dir/agy_acp_server.par"'));
    expect(unpack, contains('printf \'%s\\n\' "\$dir/agy_acp_server.par"'));
    // No checksum from the registry: none is checked, and none is invented.
    expect(unpack, isNot(contains('sha256sum')));
  });

  test('each step is bounded by the installer\'s own timeout', () async {
    final runner = FakeCommandRunner(
      environmentId: wsl.id,
      responder: (_) => ok('/home/me/x/agent\n'),
    );
    await AcpBinaryInstaller(
      runnerFor: (_) => runner,
      timeout: const Duration(minutes: 3),
    ).install(wsl, linux);
    expect(
      runner.requests.map((r) => r.timeout),
      everyElement(const Duration(minutes: 3)),
    );
  });

  test('a checksum the registry gives is checked before unpacking', () async {
    final runner = FakeCommandRunner(
      environmentId: wsl.id,
      responder: (_) => ok('/home/me/x/agent\n'),
    );
    const sha =
        'AFAA50A152EB86A8FF21E354DED63FE2D21B730859692E3A60B2C4C9ef23df31';
    await AcpBinaryInstaller(runnerFor: (_) => runner).install(
      wsl,
      const AcpAgentInstall(
        environmentId: 'wsl:arch',
        registryId: 'amp-acp',
        version: '0.9.0',
        archive: 'https://dl.example.test/amp-acp-linux-x86_64.tar.gz',
        command: './amp-acp',
        sha256: sha,
      ),
    );
    final unpack = runner.requests[1].stdinText!;
    expect(
      unpack,
      contains('echo "${sha.toLowerCase()}  \$archive" | sha256sum -c -'),
    );
    expect(unpack, contains('shasum -a 256 -c -'));
    expect(unpack, contains('tar -xzf "\$archive" -C "\$dir"'));
    expect(unpack, contains('chmod +x "\$dir/amp-acp"'));
  });

  test('on Windows: PowerShell on its stdin, under the profile', () async {
    final runner = FakeCommandRunner(
      environmentId: windows.id,
      responder: (req) => req.stdinText!.contains('Write-Output')
          ? ok(
              'C:\\Users\\me\\karmashala\\acp\\antigravity-acp\\1.3.0\\agy_acp_server.exe\r\n',
            )
          : ok(''),
    );
    final path =
        await AcpBinaryInstaller(
          runnerFor: (_) => runner,
          hostEnvironment: const {'USERPROFILE': r'C:\Users\me'},
        ).install(
          windows,
          const AcpAgentInstall(
            environmentId: 'windows',
            registryId: 'antigravity-acp',
            version: '1.3.0',
            archive:
                'https://dl.example.test/releases/windows/agy-acp-server-1.3.0-windows-x86_64.zip',
            command: './agy_acp_server.exe',
            sha256:
                '0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b0a1b',
          ),
        );
    expect(
      path,
      r'C:\Users\me\karmashala\acp\antigravity-acp\1.3.0\agy_acp_server.exe',
    );
    for (final request in runner.requests) {
      expect(request.executable, 'powershell.exe');
      expect(request.arguments, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '-',
      ]);
      expect(
        request.stdinText,
        contains(
          "\$dir = Join-Path 'C:\\Users\\me' "
          "'karmashala\\acp\\antigravity-acp\\1.3.0'",
        ),
      );
    }
    expect(
      runner.requests[0].stdinText,
      contains('Invoke-WebRequest -UseBasicParsing -Uri'),
    );
    final unpack = runner.requests[1].stdinText!;
    expect(unpack, contains('Get-FileHash -Algorithm SHA256'));
    expect(unpack, contains('Expand-Archive -Force -LiteralPath \$archive'));
    expect(
      unpack,
      contains("Write-Output (Join-Path \$dir 'agy_acp_server.exe')"),
    );
  });

  test(
    'a failed step is refused in the shell\'s words, and stops there',
    () async {
      final runner = FakeCommandRunner(
        environmentId: wsl.id,
        responder: (_) => const CommandResult(
          exitCode: 22,
          stdout: '',
          stderr: 'curl: (22) The requested URL returned error: 404\n',
        ),
      );
      final steps = <AcpInstallStep>[];
      await expectLater(
        AcpBinaryInstaller(
          runnerFor: (_) => runner,
        ).install(wsl, linux, onStep: steps.add),
        refused(DataRefusalCode.failed, 'The download failed (exit 22): curl'),
      );
      expect(runner.requests, hasLength(1));
      expect(steps, [AcpInstallStep.downloading]);
    },
  );

  test('a shell that cannot be started is refused in words', () async {
    final runner = FakeCommandRunner(
      environmentId: wsl.id,
      throwError: CommandException('Failed to run "bash" in WSL "archlinux"'),
    );
    await expectLater(
      AcpBinaryInstaller(runnerFor: (_) => runner).install(wsl, linux),
      refused(DataRefusalCode.failed, 'Failed to run "bash"'),
    );
  });

  test('an unpacking that reports no path is refused', () async {
    final runner = FakeCommandRunner(
      environmentId: wsl.id,
      responder: (_) => ok(''),
    );
    await expectLater(
      AcpBinaryInstaller(runnerFor: (_) => runner).install(wsl, linux),
      refused(DataRefusalCode.failed, 'path was not reported'),
    );
  });

  group('refused before anything runs', () {
    late FakeCommandRunner runner;
    setUp(() => runner = FakeCommandRunner(environmentId: wsl.id));

    Future<String> install(
      ExecutionEnvironment where,
      AcpAgentInstall request, {
      Map<String, String> host = const {'USERPROFILE': r'C:\Users\me'},
    }) => AcpBinaryInstaller(
      runnerFor: (_) => runner,
      hostEnvironment: host,
    ).install(where, request);

    test('an SSH box', () async {
      await expectLater(
        install(ssh, linux),
        refused(DataRefusalCode.invalid, 'not over SSH'),
      );
      expect(runner.requests, isEmpty);
    });

    test('an archive address that is not plain https', () async {
      for (final archive in [
        'ftp://x.test/a.zip',
        "https://x.test/a'.zip",
        'https://x.test/a b.zip',
        'file:///tmp/a.zip',
        // Decoded into the file name: `$(touch /tmp/x).zip`, `../../a.zip`.
        'https://x.test/%24(touch%20%2Ftmp%2Fx).zip',
        'https://x.test/%2E%2E%2F%2E%2E%2Fa.zip',
        'https://x.test/a’+(calc)+’.zip',
        'http://x.test/a.zip',
      ]) {
        await expectLater(
          install(
            wsl,
            AcpAgentInstall(
              environmentId: wsl.id,
              registryId: 'x',
              version: '1',
              archive: archive,
              command: 'x',
            ),
          ),
          refused(DataRefusalCode.invalid, 'archive address'),
          reason: archive,
        );
      }
      expect(runner.requests, isEmpty);
    });

    test('an archive kind nothing here unpacks', () async {
      await expectLater(
        install(
          wsl,
          AcpAgentInstall(
            environmentId: wsl.id,
            registryId: 'x',
            version: '1',
            archive: 'https://x.test/a.7z',
            command: 'x',
          ),
        ),
        refused(DataRefusalCode.invalid, 'unpacks .zip'),
      );
    });

    test('a command that leaves its folder, or a registry id that is not '
        'plain', () async {
      for (final (id, command) in [
        ('x', '../x'),
        ('x', 'a/../x'),
        ('x', 'x; rm -rf /'),
        ('x', ''),
        ('../x', 'x'),
        ('x y', 'x'),
      ]) {
        await expectLater(
          install(
            wsl,
            AcpAgentInstall(
              environmentId: wsl.id,
              registryId: id,
              version: '1.0',
              archive: 'https://x.test/a.zip',
              command: command,
            ),
          ),
          refused(DataRefusalCode.invalid, 'Karmashala can'),
          reason: '$id / $command',
        );
      }
      expect(runner.requests, isEmpty);
    });

    test('a checksum that is not one', () async {
      await expectLater(
        install(
          wsl,
          AcpAgentInstall(
            environmentId: wsl.id,
            registryId: 'x',
            version: '1',
            archive: 'https://x.test/a.zip',
            command: 'x',
            sha256: 'not-a-hash',
          ),
        ),
        refused(DataRefusalCode.invalid, 'sha256'),
      );
    });

    test('Windows with no profile folder known', () async {
      await expectLater(
        install(
          windows,
          const AcpAgentInstall(
            environmentId: 'windows',
            registryId: 'x',
            version: '1',
            archive: 'https://x.test/a.zip',
            command: 'x.exe',
          ),
          host: const {},
        ),
        refused(DataRefusalCode.unavailable, 'USERPROFILE'),
      );
    });
  });
}
