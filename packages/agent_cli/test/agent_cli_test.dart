import 'package:agent_cli/agent_cli.dart';
import 'package:test/test.dart';

/// The public package's own suite, kept — and repointed at the merged API.
///
/// `agent_cli` 0.1.0 was a cut-down re-derivation of Karmashala's process and
/// discovery layer with a one-shot `ask()` on top, so where the two overlapped
/// Karmashala's implementation won (docs/PACKAGE_SPLIT.md §3). Every case below
/// is the case that was here; only the symbol it exercises changed:
///
/// | 0.1.0 | now |
/// | --- | --- |
/// | `buildWslInvocation(loginShell:)` | `buildWslInvocation`, whose login shell is per *request* |
/// | `parseDistributions` | `parseWslDistributions` |
/// | `locateCommand` | `locateRequest` |
/// | `parseClaudeStreamJson` | `parseClaudeMessage` |
/// | `cliInvocation(CliAgentKind)` | `AgentAdapter.oneShot` |
/// | `parseVersion` | `parseAgentVersion` |
/// | `CliAgent` | `AgentInstallation` |
void main() {
  group('buildWslInvocation', () {
    test('separates wsl flags from the command with --', () {
      // Without the separator, `-p` is consumed by wsl instead of by claude.
      final call = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'claude', arguments: ['-p', 'hi']),
      );

      expect(call.executable, 'wsl.exe');
      expect(call.arguments, ['-d', 'Ubuntu', '--', 'claude', '-p', 'hi']);
    });

    test('a login shell is asked for per request, not per runner', () {
      // 0.1.0 made this a property of the runner. It belongs to the *lookup*:
      // `command -v` is a shell builtin with no executable to run, and
      // `~/.local/bin` is put on PATH by a login shell — but an agent that has
      // already been located needs no second shell wrapped round it.
      final call = buildWslInvocation(
        'Ubuntu',
        locateRequest(EnvironmentKind.wsl, 'claude'),
      );

      expect(call.arguments.sublist(0, 4), ['-d', 'Ubuntu', '--', 'bash']);
      expect(call.arguments[4], '-lc');
      expect(call.arguments[5], 'command -v claude');
    });

    test('quotes a prompt containing quotes and newlines', () {
      // The quoting moved to where a shell is actually involved.
      expect(posixQuote("it's here\nand here"), contains(r"it'\''s here"));
    });

    test('passes a working directory as a WSL path', () {
      final call = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(
          executable: 'ls',
          workingDirectory: EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/you',
          ),
        ),
      );
      expect(call.arguments, containsAllInOrder(['--cd', '/home/you']));
    });
  });

  group('parseWslDistributions', () {
    test('reads UTF-16 output decoded as UTF-8', () {
      // wsl --list --quiet emits UTF-16; read as UTF-8 every character is
      // followed by a zero byte. Rejecting those lines makes WSL look absent.
      const raw = 'U\u0000b\u0000u\u0000n\u0000t\u0000u\u0000\r\n';
      expect(parseWslDistributions(raw), ['Ubuntu']);
    });

    test('handles plain output too', () {
      expect(parseWslDistributions('Ubuntu\nDebian\n'), ['Ubuntu', 'Debian']);
    });

    test('ignores blank lines', () {
      expect(parseWslDistributions('\n\nUbuntu\n\n'), ['Ubuntu']);
    });

    test('keeps the space in a name, which 0.1.0 stripped', () {
      // `Docker Desktop` is a real distribution name, and this is not the only
      // parse of that output — two parses that disagree match nothing while
      // looking correct.
      expect(parseWslDistributions('Docker Desktop\n'), ['Docker Desktop']);
    });
  });

  group('locateRequest', () {
    test('uses where on a Windows host', () {
      expect(
        locateRequest(EnvironmentKind.windowsNative, 'claude').executable,
        'where',
      );
    });

    test('uses a login shell everywhere else, including inside WSL', () {
      expect(
        locateRequest(
          EnvironmentKind.localPosix,
          'claude',
          loginShell: '/bin/zsh',
        ).arguments,
        ['-lc', 'command -v claude'],
      );
      expect(locateRequest(EnvironmentKind.wsl, 'claude').executable, 'bash');
    });

    test("the local POSIX host is asked in the owner's own shell", () {
      // `bash -l` on macOS reads ~/.bash_profile and never ~/.zprofile, so on
      // a stock Mac every CLI is invisible to it.
      expect(
        locateRequest(
          EnvironmentKind.localPosix,
          'claude',
          loginShell: '/bin/zsh',
        ).executable,
        '/bin/zsh',
      );
    });
  });

  group('parseClaudeMessage', () {
    String? textIn(String line) {
      for (final event in parseClaudeMessage(line)) {
        if (event.type == SessionEventTypes.agentMessage) {
          return event.data['text'] as String?;
        }
      }
      return null;
    }

    test('extracts assistant text', () {
      const line =
          '{"type":"assistant","message":{"content":[{"type":"text","text":"one two three"}]}}';
      expect(textIn(line), 'one two three');
    });

    test('the init frame carries status, not an answer', () {
      const line = '{"type":"system","subtype":"init","tools":["Bash","Read"]}';
      expect(textIn(line), isNull);
      expect(
        parseClaudeMessage(line).single.type,
        SessionEventTypes.agentStatus,
      );
    });

    test('hooks, rate-limit events and the result object carry no text', () {
      for (final line in const [
        '{"type":"system","subtype":"hook_started"}',
        '{"type":"rate_limit_event","rate_limit_info":{}}',
        '{"type":"result","result":"one two three"}',
      ]) {
        expect(textIn(line), isNull, reason: line);
      }
    });

    test('ignores non-text blocks in an assistant message', () {
      const line =
          '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"}]}}';
      expect(
        textIn(line),
        isNull,
        reason: 'reasoning must never be spoken aloud',
      );
    });

    test('survives a partial or non-JSON line', () {
      expect(parseClaudeMessage('{"type":"assist'), isEmpty);
      expect(parseClaudeMessage('Loading...'), isEmpty);
      expect(parseClaudeMessage(''), isEmpty);
    });

    test(
      'an assistant message whose body is the wrong shape is skipped, not thrown',
      () {
        expect(
          parseClaudeMessage('{"type":"assistant","message":"oops"}'),
          isEmpty,
        );
        expect(
          parseClaudeMessage(
            '{"type":"assistant","message":{"content":"text"}}',
          ),
          isEmpty,
        );
        expect(parseClaudeMessage('{"type":"assistant"}'), isEmpty);
      },
    );
  });

  group('AgentAdapter.oneShot', () {
    test('claude runs with tools off and a replaced system prompt', () {
      // These are coding agents. Left alone they will read files and run
      // commands instead of answering a spoken question.
      final call = const ClaudeCodeAdapter().oneShot(
        'What is the capital of Nepal?',
        systemPrompt: 'You are a voice assistant.',
      );

      expect(call.arguments, containsAllInOrder(['--allowed-tools', '']));
      expect(
        call.arguments,
        containsAllInOrder(['--system-prompt', 'You are a voice assistant.']),
      );
      expect(
        call.arguments,
        containsAllInOrder(['--output-format', 'stream-json']),
      );
      expect(call.arguments.first, '-p');
    });

    test('codex is told to run outside a git repository', () {
      // It refuses otherwise, and an app's working directory is not a repo.
      final call = const CodexAdapter().oneShot('hi');
      expect(call.arguments, contains('--skip-git-repo-check'));
      expect(call.arguments, contains('--json'));
      expect(call.arguments.first, 'exec');
    });

    test('codex takes the system prompt inline, having no flag for it', () {
      final call = const CodexAdapter().oneShot(
        'What is the capital?',
        systemPrompt: 'Reply in one sentence.',
      );
      expect(
        call.arguments.last,
        'Reply in one sentence.\n\nWhat is the capital?',
      );
    });

    test('a model override reaches each CLI in its own spelling', () {
      expect(
        const ClaudeCodeAdapter().oneShot('x', model: 'sonnet').arguments,
        containsAllInOrder(['--model', 'sonnet']),
      );
      expect(
        const CodexAdapter().oneShot('x', model: 'gpt-5.1-codex').arguments,
        containsAllInOrder(['--model', 'gpt-5.1-codex']),
      );
    });

    test('an agent nobody has a descriptor for is still asked', () {
      // The prompt as its only argument, which is what a CLI with no flags
      // does — and better than refusing to ask at all.
      expect(genericOneShot(null, 'hi').arguments, ['hi']);
    });
  });

  group('parseAgentVersion', () {
    test('finds a semantic version anywhere in the output', () {
      expect(parseAgentVersion('claude 2.1.241 (Claude Code)'), '2.1.241');
      expect(parseAgentVersion('codex-cli 0.9.0-alpha.1'), '0.9.0-alpha.1');
    });

    test('falls back to the first line rather than nothing', () {
      expect(parseAgentVersion('experimental build\n'), 'experimental build');
      expect(parseAgentVersion(''), isNull);
    });
  });

  group('an installation', () {
    AgentInstallation installed(String agentId, String environmentId) =>
        AgentInstallation(
          id: '$agentId@$environmentId',
          agentId: agentId,
          executable: EnvironmentPath(
            environmentId: environmentId,
            path: '/home/you/.local/bin/$agentId',
          ),
          createdAt: DateTime.utc(2026),
        );

    test('names the CLI and where it lives', () {
      final agent = installed(AgentIds.claudeCode, 'wsl:Ubuntu');
      expect(agent.agentId, AgentIds.claudeCode);
      expect(agent.environmentId, 'wsl:Ubuntu');
      expect(
        AgentRegistry.builtIn.displayNameFor(agent.agentId),
        'Claude Code',
      );
    });

    test('the same CLI in two environments is two installations', () {
      final native = installed(AgentIds.codex, 'windows');
      final wsl = installed(AgentIds.codex, 'wsl:Ubuntu');
      expect(native.environmentId, isNot(wsl.environmentId));
      expect(native, isNot(wsl));
    });
  });
}
