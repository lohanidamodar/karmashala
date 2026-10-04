import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec;
import 'package:agent_cli/process.dart' show EnvironmentKind;
import 'package:karmashala_acp/karmashala_acp.dart' show AcpMethods;

import 'acp_auth.dart' show loginLinkIn;
import 'acp_transport.dart';

/// Whether this machine opens the login link an agent prints: in WSL the
/// agent's own opener reaches no desktop, and a bridge runs inside this
/// server with no browser of its own. Elsewhere the agent opens its own.
bool serverOpensLoginLinks(EnvironmentKind? kind, AcpLaunchSpec spec) =>
    kind == EnvironmentKind.wsl || spec.nativeBridge != null;

/// [transport] with the first https link its agent prints on stderr opened
/// through [open], and a line saying so put into the chat as an agent
/// message — at a line boundary of the agent's own output, so no message of
/// its is split.
AcpTransport openingLoginLinks(
  AcpTransport transport, {
  required void Function(Uri link) open,
  required String agentName,
}) {
  final output = StreamController<List<int>>();
  final waiting = <List<int>>[];
  var atLineStart = true;
  var opened = false;

  void flush() {
    if (!atLineStart) return;
    waiting.forEach(output.add);
    waiting.clear();
  }

  transport.output.listen(
    (chunk) {
      output.add(chunk);
      if (chunk.isNotEmpty) atLineStart = chunk.last == 0x0a;
      flush();
    },
    onError: output.addError,
    onDone: () {
      atLineStart = true;
      flush();
      unawaited(output.close());
    },
  );

  final errorLines = transport.errorLines.map((line) {
    if (opened) return line;
    final link = loginLinkIn(line);
    if (link == null) return line;
    opened = true;
    open(link);
    final said = jsonEncode({
      'jsonrpc': '2.0',
      'method': AcpMethods.sessionUpdate,
      'params': {
        'sessionId': '',
        'update': {
          'sessionUpdate': 'agent_message_chunk',
          'content': {
            'type': 'text',
            'text':
                '$agentName needs you to log in: a browser login was opened '
                'on this machine ($link). Finish signing in there and the '
                'session goes on.',
          },
          'messageId': 'karmashala-login',
        },
      },
    });
    waiting.add(utf8.encode('$said\n'));
    flush();
    return line;
  });

  return AcpTransport.streams(
    output: output.stream,
    input: transport.input,
    exitCode: transport.exitCode,
    errorLines: errorLines,
    kill: transport.kill,
  );
}
