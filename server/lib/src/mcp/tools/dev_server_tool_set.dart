import '../../terminals/server_terminals.dart';
import 'server_tool_set.dart';

/// `terminal_ports`: the dev servers Karmashala's panes have started — the
/// TCP ports processes under each local pane listen on, read when called.
class DevServerToolSet extends ServerToolSet {
  const DevServerToolSet(this.terminals);

  final ServerTerminals terminals;

  @override
  List<Map<String, Object?>> get schemas => devServerToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => tool != 'terminal_ports'
      ? null
      : runTool(() async {
          final mine = arguments['mine'] == true;
          if (mine && callerSessionId == null) {
            throw ArgumentError(
              'mine: true needs a calling session, and this caller is not '
              'running inside one.',
            );
          }
          final reading = await terminals.listeningPorts();
          final ports = [
            for (final port in reading.ports)
              if (!mine || port.agentSessionId == callerSessionId) port,
          ];
          return <String, Object?>{
            'checkedAt': reading.checkedAt.toIso8601String(),
            'ports': [
              for (final port in ports) {...port.toJson(), 'url': port.url},
            ],
            if (reading.unread.isNotEmpty) 'notRead': reading.unread,
          };
        });
}

/// The schemas for [DevServerToolSet].
const List<Map<String, Object?>> devServerToolSchemas = [
  {
    'name': 'terminal_ports',
    'description':
        'The TCP ports that processes started in Karmashala\'s terminal and '
        'agent panes are listening on — the dev servers — with the pane, the '
        'process and a localhost URL. Read when called, never polled; a pane '
        'in WSL or on an SSH machine is listed under notRead, not as having '
        'none. Open one beside your session with browser_navigate.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'mine': {
          'type': 'boolean',
          'description': 'Only ports under the calling session\'s own pane.',
        },
      },
    },
  },
];
