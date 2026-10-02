// Checks the ACP names `packages/karmashala_acp` hard-codes against the
// protocol's published schema, so a vocabulary change upstream is noticed
// rather than discovered as an `unknown(raw)` in a session.
//
//   dart run tool/acp_schema_check.dart            # downloads the latest schema
//   dart run tool/acp_schema_check.dart --schema <file>
//
// Every method, `sessionUpdate` value and enum value the package names must
// exist in the schema; one that does not is drift, printed and exit 1.
// Values the schema has and the package does not are printed as a note:
// they reach a session as `unknown(raw)`, which is tolerated by design.
//
// Run from the repository root: the workspace's package_config resolves the
// package import.
import 'dart:convert';
import 'dart:io';

// The workspace root declares no dependencies of its own; the member's
// package resolves through the shared package_config.
// ignore: depend_on_referenced_packages
import 'package:karmashala_acp/vocabulary.dart';

const schemaUrl =
    'https://github.com/agentclientprotocol/agent-client-protocol/releases/latest/download/schema.json';

Future<void> main(List<String> args) async {
  final schemaIndex = args.indexOf('--schema');
  final text = schemaIndex >= 0
      ? File(args[schemaIndex + 1]).readAsStringSync()
      : await _download(Uri.parse(schemaUrl));
  final schema = jsonDecode(text) as Map<String, Object?>;
  final defs = schema[r'$defs'] as Map<String, Object?>;

  final methods = <String>{};
  _collectMethods(schema, methods);

  final checks = <_Check>[
    _Check(
      'agent methods',
      AcpVocabulary.agentMethods,
      methods.where((m) => _side(defs, m) == 'agent').toSet(),
    ),
    _Check(
      'client methods',
      AcpVocabulary.clientMethods,
      methods.where((m) => _side(defs, m) == 'client').toSet(),
    ),
    _Check(
      'transport methods',
      AcpVocabulary.transportMethods,
      methods.where((m) => _side(defs, m) == 'protocol').toSet(),
    ),
    _Check(
      'sessionUpdate',
      AcpVocabulary.sessionUpdates,
      _variants(defs, 'SessionUpdate', property: 'sessionUpdate'),
    ),
    _Check(
      'StopReason',
      AcpVocabulary.stopReasons,
      _variants(defs, 'StopReason'),
    ),
    _Check('ToolKind', AcpVocabulary.toolKinds, _variants(defs, 'ToolKind')),
    _Check(
      'ToolCallStatus',
      AcpVocabulary.toolCallStatuses,
      _variants(defs, 'ToolCallStatus'),
    ),
    _Check(
      'PermissionOptionKind',
      AcpVocabulary.permissionOptionKinds,
      _variants(defs, 'PermissionOptionKind'),
    ),
    _Check(
      'PlanEntryPriority',
      AcpVocabulary.planEntryPriorities,
      _variants(defs, 'PlanEntryPriority'),
    ),
    _Check(
      'PlanEntryStatus',
      AcpVocabulary.planEntryStatuses,
      _variants(defs, 'PlanEntryStatus'),
    ),
    _Check(
      'ContentBlock.type',
      AcpVocabulary.contentBlockTypes,
      _variants(defs, 'ContentBlock', property: 'type'),
    ),
    _Check(
      'ToolCallContent.type',
      AcpVocabulary.toolCallContentTypes,
      _variants(defs, 'ToolCallContent', property: 'type'),
    ),
    _Check(
      'RequestPermissionOutcome.outcome',
      AcpVocabulary.permissionOutcomes,
      _variants(defs, 'RequestPermissionOutcome', property: 'outcome'),
    ),
    _Check('ErrorCode', [
      for (final c in AcpVocabulary.errorCodes) '$c',
    ], _variants(defs, 'ErrorCode')),
  ];

  var drifted = false;
  for (final check in checks) {
    final missing = check.ours.where((v) => !check.theirs.contains(v)).toList();
    final extra = check.theirs.where((v) => !check.ours.contains(v)).toList();
    if (check.theirs.isEmpty) {
      drifted = true;
      stdout.writeln('DRIFT ${check.name}: nothing found in the schema');
      continue;
    }
    if (missing.isNotEmpty) {
      drifted = true;
      stdout.writeln(
        'DRIFT ${check.name}: not in schema: ${missing.join(', ')}',
      );
    }
    if (extra.isNotEmpty) {
      stdout.writeln(
        'note  ${check.name}: in schema, not modelled: ${extra.join(', ')}',
      );
    }
    if (missing.isEmpty) {
      stdout.writeln('ok    ${check.name} (${check.ours.length})');
    }
  }
  if (drifted) {
    stdout.writeln('ACP vocabulary drifted from the schema.');
    exit(1);
  }
  stdout.writeln('ACP vocabulary matches the schema.');
}

Future<String> _download(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    request.followRedirects = true;
    request.maxRedirects = 10;
    final response = await request.close();
    if (response.statusCode != 200) {
      stderr.writeln('GET $url answered ${response.statusCode}');
      exit(2);
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

/// Every `x-method` anywhere in the schema.
void _collectMethods(Object? node, Set<String> into) {
  if (node is Map<String, Object?>) {
    if (node['x-method'] case final String method) into.add(method);
    for (final value in node.values) {
      _collectMethods(value, into);
    }
  } else if (node is List) {
    for (final value in node) {
      _collectMethods(value, into);
    }
  }
}

/// Which side answers [method]: the `x-side` of a request def naming it.
String? _side(Map<String, Object?> defs, String method) {
  for (final def in defs.values) {
    if (def is Map<String, Object?> && def['x-method'] == method) {
      if (def['x-side'] case final String side) return side;
    }
  }
  return null;
}

/// The `const` of each `oneOf`/`anyOf` variant of a def, read directly for
/// a string enum or under `properties/<property>` for a tagged union.
Set<String> _variants(
  Map<String, Object?> defs,
  String name, {
  String? property,
}) {
  final def = defs[name];
  if (def is! Map<String, Object?>) return {};
  final variants = (def['oneOf'] ?? def['anyOf']) as List? ?? const [];
  final result = <String>{};
  for (final variant in variants) {
    if (variant is! Map<String, Object?>) continue;
    Object? value;
    if (property == null) {
      value = variant['const'];
    } else {
      final properties = variant['properties'];
      if (properties is Map<String, Object?>) {
        final field = properties[property];
        if (field is Map<String, Object?>) value = field['const'];
      }
    }
    if (value != null) result.add('$value');
  }
  return result;
}

class _Check {
  const _Check(this.name, this.ours, this.theirs);

  final String name;
  final List<String> ours;
  final Set<String> theirs;
}
