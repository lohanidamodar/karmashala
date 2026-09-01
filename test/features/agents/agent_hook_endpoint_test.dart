import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:flutter_test/flutter_test.dart';

/// The callback address an agent is told to post to, per environment.
///
/// One endpoint cannot serve one URL to everybody: `127.0.0.1` inside a WSL2
/// distribution is the distribution's own loopback, so the URL that is right
/// for a Windows-native pane is refused from inside a distro. Measured from
/// this machine against a two-door server on one port:
///
/// ```
/// $ curl … http://127.0.0.1:56566/agent-hook       # from WSL → refused
/// $ curl … http://172.18.240.1:56566/agent-hook    # from WSL → {"ok":true}
/// ```
void main() {
  const wslSwitch = '172.18.240.1';

  group('the URL a hook is given', () {
    test('a Windows-native agent keeps loopback', () {
      const endpoint = AgentHookEndpoint(
        port: 4242,
        token: 'tok',
        wslHost: wslSwitch,
      );

      expect(
        endpoint.uriFor(
          agentId: 'claudeCode',
          event: 'Stop',
          environment: EnvironmentKind.windowsNative,
        ).toString(),
        'http://127.0.0.1:4242/agent-hook?agent=claudeCode&event=Stop',
      );
    });

    test('a WSL agent is given the switch address, on the same port', () {
      const endpoint = AgentHookEndpoint(
        port: 4242,
        token: 'tok',
        wslHost: wslSwitch,
      );

      final uri = endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.wsl,
      )!;

      expect(uri.host, wslSwitch);
      // One server, two doors: a second port would need a second bind and a
      // second thing to keep in step.
      expect(uri.port, 4242);
      expect(uri.path, '/agent-hook');
    });

    test('a WSL agent on a host with no switch is given nothing', () {
      // Not loopback, which the distribution refuses. An installed hook that
      // cannot arrive is worse than no hook at all, because nothing reports it.
      const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');

      expect(
        endpoint.uriFor(
          agentId: 'claudeCode',
          event: 'Stop',
          environment: EnvironmentKind.wsl,
        ),
        isNull,
      );
      expect(
        endpoint.uriFor(
          agentId: 'claudeCode',
          event: 'Stop',
          environment: EnvironmentKind.windowsNative,
        ),
        isNotNull,
      );
    });

    test('an SSH agent is given nothing, switch address or not', () {
      // Every address this app binds is local to the machine, and reaching a
      // remote host would mean binding an interface the LAN can see.
      const endpoint = AgentHookEndpoint(
        port: 4242,
        token: 'tok',
        wslHost: wslSwitch,
      );

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
      const withSwitch = AgentHookEndpoint(
        port: 1,
        token: 't',
        wslHost: wslSwitch,
      );
      const withoutSwitch = AgentHookEndpoint(port: 1, token: 't');

      expect(withSwitch.reaches(EnvironmentKind.windowsNative), isTrue);
      expect(withSwitch.reaches(EnvironmentKind.wsl), isTrue);
      expect(withSwitch.reaches(EnvironmentKind.ssh), isFalse);
      expect(withoutSwitch.reaches(EnvironmentKind.windowsNative), isTrue);
      expect(withoutSwitch.reaches(EnvironmentKind.wsl), isFalse);
    });
  });

  test('the WSL address is carried in, never reached for', () {
    // `agents/` must not depend on `mcp/`: the installer is what writes this
    // into an agent's own config, and the address is resolved by whoever bound
    // the socket. Constructing one with a plain string is the whole contract.
    const endpoint = AgentHookEndpoint(
      port: 9,
      token: 't',
      wslHost: '10.0.0.1',
    );

    expect(endpoint.wslHost, '10.0.0.1');
  });
}
