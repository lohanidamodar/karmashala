import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host_protocol/host_paths.dart';

import '../serve/client_command.dart';

/// `karmashala_host transcript <session-id>`: one page of a session's
/// transcript as the running server reads it (`sessions.transcript`) — what
/// a desktop on another machine is sent. `--watch` then prints each
/// `transcriptChanged` until interrupted.
Future<int> runTranscript(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Map<String, String>? environment,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final named = args.where((a) => !a.startsWith('--')).toList();
  if (named.isEmpty) {
    errSink.writeln('karmashala_host transcript: name a session (see `list`)');
    return 2;
  }
  int? number(String flag) {
    for (final arg in args) {
      if (arg.startsWith('--$flag=')) {
        return int.tryParse(arg.substring(flag.length + 3));
      }
    }
    return null;
  }

  String? text(String flag) {
    for (final arg in args) {
      if (arg.startsWith('--$flag=')) return arg.substring(flag.length + 3);
    }
    return null;
  }

  final sessionId = named.first;
  // `--subagent=<path>`: a delegate's turns, as an expanded `Task` row asks.
  final subagent = text('subagent');
  // `--turns [--spoken]`: the text-only pages export and recap read;
  // `--digest=<first row held>`: the plan and open calls before it (step 8).
  final DataRequest<TranscriptPage> request = subagent != null
      ? SessionTranscriptSubagent(
          sessionId,
          subagent,
          after: number('after'),
          limit: number('limit'),
        )
      : args.contains('--turns')
      ? SessionTranscriptTurns(
          sessionId,
          before: number('before'),
          limit: number('limit'),
          generation: text('generation'),
          spoken: args.contains('--spoken'),
        )
      : SessionTranscriptRead(
          sessionId,
          after: number('after'),
          before: number('before'),
          limit: number('limit'),
          generation: text('generation'),
          revision: number('revision'),
          digest: number('digest'),
        );
  final resolved = hostPathsFor(
    'transcript',
    paths: paths,
    environment: environment,
  );
  final HostClient? client;
  try {
    client = await HostClient.connect(resolved.socketPath);
  } on HostClientRefusal catch (error) {
    errSink.writeln('karmashala_host transcript: $error');
    return 6;
  }
  if (client == null) {
    errSink.writeln(
      'karmashala_host transcript: no server at ${resolved.socketPath}',
    );
    return 5;
  }
  try {
    // `--read=rewindPoints|changedFiles|openQuestion`: a raw-line reader's
    // answer (Stage 0 step 7), as the wire carries it. `--read=stats
    // [--lifetime]` counts every session named, in one request (step 9).
    final reader = text('read');
    if (reader != null) {
      Future<Object?> read<R>(DataRequest<R> ask) async =>
          ask.resultToJson((await client!.data(ask)).value);
      final answer = await switch (reader) {
        'rewindPoints' => read(SessionRewindPointsRead(sessionId)),
        'changedFiles' => read(SessionChangedFilesRead(sessionId)),
        'openQuestion' => read(SessionOpenQuestionRead(sessionId)),
        'stats' => read(
          SessionStatsRead(named, lifetime: args.contains('--lifetime')),
        ),
        _ => throw DataRefused.invalid('no reader named $reader'),
      };
      sink.writeln(const JsonEncoder.withIndent('  ').convert(answer));
      return 0;
    }
    final page = (await client.data(request)).value;
    if (args.contains('--json')) {
      sink.writeln(const JsonEncoder.withIndent('  ').convert(page.toJson()));
    } else {
      _printPage(sink, page);
    }
    if (!args.contains('--watch')) return 0;
    final done = Completer<int>();
    final changes = client.dataChanges.listen((batch) {
      for (final change in batch.changes) {
        if (change is TranscriptChanged && change.sessionId == sessionId) {
          sink.writeln(
            'transcriptChanged generation=${change.generation} '
            'revision=${change.revision} total=${change.total}',
          );
        }
      }
    }, onDone: () => done.isCompleted ? null : done.complete(0));
    await client.data(SessionTranscriptWatch(sessionId));
    sink.writeln('watching; Ctrl+C to stop');
    final code = await done.future;
    await changes.cancel();
    return code;
  } on DataRefused catch (refusal) {
    errSink.writeln('karmashala_host transcript: ${refusal.message}');
    return 6;
  } on HostClientRefusal catch (error) {
    errSink.writeln('karmashala_host transcript: $error');
    return 6;
  } finally {
    await client.close();
  }
}

void _printPage(IOSink sink, TranscriptPage page) {
  sink.writeln(
    'generation=${page.generation} revision=${page.revision} '
    'total=${page.total} from=${page.from} messages=${page.messages.length}'
    '${page.updates.isEmpty ? '' : ' updates=${page.updates.length}'}'
    '${page.reset ? ' reset' : ''}'
    '${page.absence == null ? '' : ' absence=${page.absence!.name}'}',
  );
  if (page.path != null) sink.writeln('path=${page.path}');
  if (page.digest case final digest?) {
    sink.writeln(
      'digest end=${digest.end} plan=${digest.plan?.index ?? 'none'} '
      'pending=${[for (final row in digest.pending) row.index].join(',')}',
    );
  }
  void line(int index, TranscriptMessage message) {
    final tool = message.tool;
    final body = tool != null ? tool.summary : message.text.split('\n').first;
    final short = body.length > 100 ? '${body.substring(0, 100)}…' : body;
    final flags = [
      if (message.pendingToolUseId != null) 'pending',
      if (message.pendingBackgroundAgentId != null) 'background',
      if (message.subagent != null) 'subagent',
      if (message.compaction != null) 'compaction',
      if (message.thinking != null) 'thinking',
    ];
    sink.writeln(
      '[$index] ${message.role}: $short'
      '${flags.isEmpty ? '' : '  (${flags.join(', ')})'}',
    );
  }

  for (final update in page.updates) {
    line(update.index, update.message);
  }
  for (var i = 0; i < page.messages.length; i++) {
    line(page.from + i, page.messages[i]);
  }
}
