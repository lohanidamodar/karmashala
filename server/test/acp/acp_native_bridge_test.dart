import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/src/acp/acp_native_bridge.dart';
import 'package:karmashala_host/src/acp/acp_transport.dart';
import 'package:test/test.dart';

/// An agent spoken to in its own protocol is translated to ACP where its
/// process is opened, so the runtime, the login and the version read all see
/// ACP; an agent that speaks ACP itself is handed through untouched.
void main() {
  AcpTransport raw() => AcpTransport.streams(
    output: const Stream.empty(),
    input: StreamController<List<int>>(),
    exitCode: Completer<int>().future,
  );

  test('an ACP agent\'s process is its transport', () {
    final process = raw();
    expect(bridgedAcpTransport(const AcpLaunchSpec(), process), same(process));
  });

  test('a native agent\'s process is wrapped by its bridge', () {
    final process = raw();
    final translated = raw();
    AcpTransport? wrapped;
    final bridged = bridgedAcpTransport(
      const AcpLaunchSpec(nativeBridge: AcpNativeBridge.codexAppServer),
      process,
      bridges: {
        AcpNativeBridge.codexAppServer: (p) {
          wrapped = p;
          return translated;
        },
      },
    );
    expect(wrapped, same(process));
    expect(bridged, same(translated));
  });

  test('a bridge this build lacks is refused in words', () {
    expect(
      () => bridgedAcpTransport(
        const AcpLaunchSpec(nativeBridge: AcpNativeBridge.claudeStreamJson),
        raw(),
        bridges: const {},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('claudeStreamJson'),
        ),
      ),
    );
  });

  test('a spec keeps its bridge when an auth method is chosen', () {
    const spec = AcpLaunchSpec(nativeBridge: AcpNativeBridge.codexAppServer);
    expect(
      spec.withAuthMethod('chatgpt').nativeBridge,
      AcpNativeBridge.codexAppServer,
    );
  });
}
