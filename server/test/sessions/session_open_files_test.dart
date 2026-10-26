import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/sessions/session_open_files.dart';
import 'package:test/test.dart';

/// What a waiting session's process holds open, read on WSL or Linux. The
/// script itself is not run here; the output below is the shape it printed
/// for the owner's two Codex panes on 2026-10-26.
void main() {
  test('the output is filed by session, transcripts only', () {
    const dir = '/home/dlohani/.codex/sessions/2026/10/26';
    final open = parseSessionOpenFiles(
      '7c0ea713 $dir/rollout-2026-10-26T13-53-02-01a17740-8ede.jsonl\n'
      '7c0ea713 $dir/rollout-2026-10-26T13-49-10-01a1773d-079a.jsonl\n'
      '3f46412b $dir/rollout-2026-10-26T13-49-10-01a1773d-0841.jsonl\n'
      '3f46412b /tmp/not-a-transcript.log\n'
      'garbage\n',
    );
    expect(open.keys, unorderedEquals(['7c0ea713', '3f46412b']));
    expect(open['7c0ea713'], hasLength(2));
    expect(open['3f46412b'], {
      '$dir/rollout-2026-10-26T13-49-10-01a1773d-0841.jsonl',
    });
  });

  test('a file is the same file in either spelling', () {
    expect(
      transcriptFileName(
        r'\\wsl.localhost\archlinux\home\u\.codex\sessions\rollout-x.jsonl',
      ),
      'rollout-x.jsonl',
    );
    expect(
      transcriptFileName('/home/u/.codex/rollout-x.jsonl'),
      'rollout-x.jsonl',
    );
  });

  test('only a well-formed session id reaches the script', () {
    final script = sessionOpenFilesScript({'7c0ea713-31d9', r'$(rm -rf /)'});
    expect(script, contains(' 7c0ea713-31d9 '));
    expect(script, isNot(contains('rm -rf')));
  });

  test('only WSL from Windows and this Linux machine are looked inside', () {
    ExecutionEnvironment env(EnvironmentKind kind) => ExecutionEnvironment(
      id: kind.name,
      kind: kind,
      name: kind.name,
      wslDistribution: 'archlinux',
      createdAt: DateTime.utc(2026),
    );
    final distributions = <String?>[];
    Future<String> shell(String script) async => '';
    final onWindows = sessionOpenFilesOnThisMachine(
      windows: true,
      linux: false,
      wsl: (distribution) {
        distributions.add(distribution);
        return shell;
      },
      local: shell,
    );
    expect(onWindows(env(EnvironmentKind.wsl), {'s'}), isNotNull);
    expect(distributions, ['archlinux']);
    expect(onWindows(env(EnvironmentKind.windowsNative), {'s'}), isNull);
    expect(onWindows(env(EnvironmentKind.ssh), {'s'}), isNull);

    final onLinux = sessionOpenFilesOnThisMachine(
      windows: false,
      linux: true,
      local: shell,
    );
    expect(onLinux(env(EnvironmentKind.localPosix), {'s'}), isNotNull);
    expect(onLinux(env(EnvironmentKind.wsl), {'s'}), isNull);
  });
}
