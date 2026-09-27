import 'dart:async';

import 'package:agent_cli/process.dart' show CommandException;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;

/// [error] in words worth showing a person — never "Bad state:" or a class
/// name. What reaches the app is the server's refusal (its own words) or a
/// local failure; SSH's own are worded at the server (slice 5d).
String describeFailure(Object error) => switch (error) {
  DataRefused e => e.message,
  CommandException e => e.message,
  StateError e => e.message,
  ArgumentError e => '${e.message ?? e}',
  TimeoutException e =>
    'It did not answer in time'
        '${e.duration == null ? '' : ' (${e.duration!.inSeconds} s)'}.',
  _ => error.toString(),
};
