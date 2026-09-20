import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:test/test.dart';

/// How an agent is told to report, per environment.
///
/// One endpoint cannot serve one answer to everybody, and the difference is not
/// only which address: `127.0.0.1` inside a WSL2 distribution is that
/// distribution's own loopback, and the one address of ours it *can* name — the
/// host side of the Hyper-V switch — completed the handshake and reset the
/// first data segment on the machine this was written for, for our port and for
/// 135 and 445 alike, and did the same to a bare PowerShell `TcpListener`.
///
/// So a WSL agent is not given an address at all. It is given a spool
/// directory in its own store home, which the app reads over `\\wsl.localhost`.
void main() {
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');

  group('the transport a hook is given', () {
    test('a Windows-native agent posts to loopback', () {
      final transport = endpoint.transportFor(EnvironmentKind.windowsNative);

      expect(transport, isA<AgentHookHttpTransport>());
      expect(
        (transport! as AgentHookHttpTransport).authority,
        '127.0.0.1:4242',
      );
      expect(
        endpoint
            .uriFor(
              agentId: 'claudeCode',
              event: 'Stop',
              environment: EnvironmentKind.windowsNative,
            )
            .toString(),
        'http://127.0.0.1:4242/agent-hook?agent=claudeCode&event=Stop',
      );
    });

    test('a local POSIX agent posts to the same loopback', () {
      expect(
        endpoint.transportFor(EnvironmentKind.localPosix),
        isA<AgentHookHttpTransport>(),
      );
    });

    test('a WSL agent spools, and is given no URL to get wrong', () {
      expect(
        endpoint.transportFor(EnvironmentKind.wsl),
        isA<AgentHookSpoolTransport>(),
      );
      // Not loopback, which the distribution refuses; and not the switch
      // address either, which accepts a connection and then resets it. An
      // installed hook that cannot arrive is worse than no hook at all,
      // because nothing reports it.
      expect(endpoint.hostFor(EnvironmentKind.wsl), isNull);
      expect(
        endpoint.uriFor(
          agentId: 'claudeCode',
          event: 'Stop',
          environment: EnvironmentKind.wsl,
        ),
        isNull,
      );
    });

    test('an SSH agent is given nothing at all', () {
      // Another machine: it shares neither a loopback nor a filesystem with
      // this process, and reaching it would mean binding an interface the LAN
      // can see.
      expect(endpoint.transportFor(EnvironmentKind.ssh), isNull);
      expect(
        endpoint.uriFor(
          agentId: 'claudeCode',
          event: 'Stop',
          environment: EnvironmentKind.ssh,
        ),
        isNull,
      );
    });
  });

  group('reaches', () {
    test('answers for every environment kind', () {
      expect(endpoint.reaches(EnvironmentKind.windowsNative), isTrue);
      expect(endpoint.reaches(EnvironmentKind.localPosix), isTrue);
      expect(endpoint.reaches(EnvironmentKind.wsl), isTrue);
      expect(endpoint.reaches(EnvironmentKind.ssh), isFalse);
    });

    test('WSL no longer depends on anything this app managed to bind', () {
      // The headline of the change. Every field this type has is about the
      // loopback listener, and a WSL agent's answer does not read one of them —
      // which is why a launch that never saw a switch address still installs
      // WSL hooks that work.
      const other = AgentHookEndpoint(port: 1, token: 'x');

      expect(
        other.transportFor(EnvironmentKind.wsl),
        isA<AgentHookSpoolTransport>(),
      );
    });
  });

  test('the token belongs to the networked transport and nothing else', () {
    // Stated as a test because it is a security property, not a detail: the
    // spool never crosses a network, so it carries no credential to leave at
    // rest inside somebody's distribution.
    final http =
        endpoint.transportFor(EnvironmentKind.windowsNative)!
            as AgentHookHttpTransport;

    expect(http.token, 'tok');
    expect(
      endpoint.transportFor(EnvironmentKind.wsl),
      isA<AgentHookTransport>(),
    );
    expect(
      endpoint.transportFor(EnvironmentKind.wsl),
      isNot(isA<AgentHookHttpTransport>()),
    );
  });
}
