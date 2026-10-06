/// The mermaid diagrams Karmashala draws itself — flowcharts and sequence
/// diagrams — read into values a painter lays out. Anything else is
/// [MermaidUnsupported], so a reader is told which type and still has the
/// source; nothing here runs mermaid's JavaScript.
sealed class MermaidParse {
  const MermaidParse();
}

/// The source could not be read; [reason] names the line.
final class MermaidError extends MermaidParse {
  const MermaidError(this.reason);

  final String reason;
}

/// A diagram type this renderer does not draw, such as `gantt`.
final class MermaidUnsupported extends MermaidParse {
  const MermaidUnsupported(this.type);

  final String type;
}

enum MermaidDirection { topDown, bottomUp, leftRight, rightLeft }

enum MermaidShape {
  rect,
  round,
  stadium,
  subroutine,
  cylinder,
  circle,
  diamond,
  hexagon,
  flag,
  parallelogram,
}

enum MermaidLine { solid, dotted, thick }

class MermaidNode {
  const MermaidNode(this.id, this.label, this.shape);

  final String id;
  final String label;
  final MermaidShape shape;
}

class MermaidEdge {
  const MermaidEdge({
    required this.from,
    required this.to,
    required this.line,
    required this.arrow,
    this.label,
  });

  final String from;
  final String to;
  final MermaidLine line;
  final bool arrow;
  final String? label;
}

final class MermaidFlowchart extends MermaidParse {
  const MermaidFlowchart(this.direction, this.nodes, this.edges);

  final MermaidDirection direction;
  final List<MermaidNode> nodes;
  final List<MermaidEdge> edges;

  MermaidNode node(String id) => nodes.firstWhere((n) => n.id == id);
}

class MermaidParticipant {
  const MermaidParticipant(this.id, this.label, {this.actor = false});

  final String id;
  final String label;
  final bool actor;
}

/// One row of a sequence diagram, top to bottom.
sealed class MermaidStep {
  const MermaidStep();
}

enum MermaidMessageEnd { arrow, open, cross, async }

final class MermaidMessage extends MermaidStep {
  const MermaidMessage({
    required this.from,
    required this.to,
    required this.text,
    required this.dashed,
    required this.end,
  });

  final String from;
  final String to;
  final String text;
  final bool dashed;
  final MermaidMessageEnd end;
}

final class MermaidNote extends MermaidStep {
  const MermaidNote(this.over, this.text, {this.side});

  /// The participants it sits over, or the one beside it.
  final List<String> over;
  final String text;

  /// `left` or `right` of [over]'s one participant; null when over.
  final String? side;
}

/// `loop`, `alt`, `opt`, `par`, `critical`, `break` or `rect` opening, or an
/// `else`/`and` dividing one.
final class MermaidBlockStart extends MermaidStep {
  const MermaidBlockStart(this.kind, this.label);

  final String kind;
  final String label;
}

final class MermaidBlockDivider extends MermaidStep {
  const MermaidBlockDivider(this.label);

  final String label;
}

final class MermaidBlockEnd extends MermaidStep {
  const MermaidBlockEnd();
}

final class MermaidSequence extends MermaidParse {
  const MermaidSequence(this.participants, this.steps, {this.autonumber = false});

  final List<MermaidParticipant> participants;
  final List<MermaidStep> steps;
  final bool autonumber;
}

/// Reads [source]. Never throws: a source it cannot read is a [MermaidError].
MermaidParse parseMermaid(String source) {
  final lines = <(int, String)>[];
  for (final (i, raw) in source.split('\n').indexed) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('%%')) continue;
    lines.add((i + 1, line));
  }
  if (lines.isEmpty) return const MermaidError('There is no diagram to draw.');
  final header = lines.first.$2;
  final type = header.split(RegExp(r'\s+')).first;
  try {
    return switch (type) {
      'graph' || 'flowchart' => _Flowchart(header, lines.skip(1)).parse(),
      'sequenceDiagram' => _parseSequence(lines.skip(1)),
      _ => MermaidUnsupported(type.replaceAll(RegExp(r'[-:].*$'), '')),
    };
  } on _ParseFailure catch (failure) {
    return MermaidError(failure.message);
  }
}

class _ParseFailure implements Exception {
  _ParseFailure(this.message);

  final String message;
}

const _ignoredFlowchartLines = {
  'subgraph',
  'end',
  'classDef',
  'class',
  'style',
  'linkStyle',
  'click',
  'direction',
};

class _Flowchart {
  _Flowchart(this.header, this.lines);

  final String header;
  final Iterable<(int, String)> lines;
  final _nodes = <String, MermaidNode>{};
  final _edges = <MermaidEdge>[];

  MermaidFlowchart parse() {
    final word = header.split(RegExp(r'\s+')).skip(1).firstOrNull;
    final direction = switch (word?.toUpperCase().replaceAll(';', '')) {
      'LR' => MermaidDirection.leftRight,
      'RL' => MermaidDirection.rightLeft,
      'BT' => MermaidDirection.bottomUp,
      _ => MermaidDirection.topDown,
    };
    // A header may carry statements after `;`, as `graph TB; A --> B`.
    final rest = header.contains(';')
        ? header.substring(header.indexOf(';') + 1)
        : '';
    final all = [
      if (rest.trim().isNotEmpty) (1, rest),
      ...lines,
    ];
    for (final (number, line) in all) {
      for (final statement in _splitStatements(line)) {
        final first = statement.split(RegExp(r'\s+')).first;
        if (_ignoredFlowchartLines.contains(first)) continue;
        _statement(statement, number);
      }
    }
    if (_nodes.isEmpty) throw _ParseFailure('The flowchart has no nodes.');
    return MermaidFlowchart(direction, _nodes.values.toList(), _edges);
  }

  void _statement(String text, int line) {
    final reader = _Reader(text, line);
    var left = _nodeGroup(reader);
    while (!reader.done) {
      final edge = _edge(reader);
      final right = _nodeGroup(reader);
      for (final from in left) {
        for (final to in right) {
          _edges.add(
            MermaidEdge(
              from: from,
              to: to,
              line: edge.line,
              arrow: edge.arrow,
              label: edge.label,
            ),
          );
        }
      }
      left = right;
    }
  }

  List<String> _nodeGroup(_Reader reader) {
    final ids = [_node(reader)];
    while (reader.take(RegExp(r'\s*&\s*')) != null) {
      ids.add(_node(reader));
    }
    return ids;
  }

  String _node(_Reader reader) {
    final id = reader.take(RegExp(r'\s*([\p{L}\p{N}_][\p{L}\p{N}_.]*)', unicode: true));
    if (id == null) reader.fail('a node id');
    final name = id[1]!;
    final shaped = _shape(reader);
    reader.take(RegExp(r':::[\w-]+'));
    if (shaped != null) {
      _nodes[name] = MermaidNode(name, shaped.$2, shaped.$1);
    } else {
      _nodes.putIfAbsent(name, () => MermaidNode(name, name, MermaidShape.rect));
    }
    return name;
  }

  static const _openers = [
    ('([', '])', MermaidShape.stadium),
    ('[[', ']]', MermaidShape.subroutine),
    ('[(', ')]', MermaidShape.cylinder),
    ('((', '))', MermaidShape.circle),
    ('{{', '}}', MermaidShape.hexagon),
    ('[/', '/]', MermaidShape.parallelogram),
    (r'[\', r'\]', MermaidShape.parallelogram),
    ('[', ']', MermaidShape.rect),
    ('(', ')', MermaidShape.round),
    ('{', '}', MermaidShape.diamond),
    ('>', ']', MermaidShape.flag),
  ];

  (MermaidShape, String)? _shape(_Reader reader) {
    for (final (open, close, shape) in _openers) {
      if (!reader.rest.startsWith(open)) continue;
      reader.pos += open.length;
      final label = reader.until(close);
      return (shape, _label(label));
    }
    return null;
  }

  static final _plainEdge = RegExp(
    r'^\s*<?(-{2,}|={2,}|-\.+-)(>|x|o)?(?:\|([^|]*)\|)?',
  );
  static final _labelledEdge = RegExp(
    r'^\s*<?(--|==|-\.)\s+([^|]+?)\s+(-{2,}|={2,}|\.+-)(>|x|o)?',
  );

  ({MermaidLine line, bool arrow, String? label}) _edge(_Reader reader) {
    final labelled = _labelledEdge.firstMatch(reader.rest);
    if (labelled != null) {
      reader.pos += labelled[0]!.length;
      return (
        line: _lineOf(labelled[1]!),
        arrow: labelled[4] != null,
        label: _label(labelled[2]!),
      );
    }
    final plain = _plainEdge.firstMatch(reader.rest);
    if (plain == null) reader.fail('an arrow such as -->');
    reader.pos += plain[0]!.length;
    final label = plain[3]?.trim();
    return (
      line: _lineOf(plain[1]!),
      arrow: plain[2] != null,
      label: label == null || label.isEmpty ? null : _label(label),
    );
  }

  static MermaidLine _lineOf(String stroke) => stroke.contains('.')
      ? MermaidLine.dotted
      : stroke.startsWith('=')
      ? MermaidLine.thick
      : MermaidLine.solid;
}

/// A label as drawn: quotes and markdown backticks off, `<br>` a new line.
String _label(String raw) {
  var text = raw.trim();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    text = text.substring(1, text.length - 1);
  }
  if (text.length >= 2 && text.startsWith('`') && text.endsWith('`')) {
    text = text.substring(1, text.length - 1);
  }
  return text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll('#quot;', '"')
      .trim();
}

/// [line] split at `;` outside brackets and quotes.
List<String> _splitStatements(String line) {
  final out = <String>[];
  var depth = 0;
  var quoted = false;
  var start = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') quoted = !quoted;
    if (quoted) continue;
    if ('[({'.contains(c)) depth++;
    if ('])}'.contains(c) && depth > 0) depth--;
    if (c == ';' && depth == 0) {
      out.add(line.substring(start, i));
      start = i + 1;
    }
  }
  out.add(line.substring(start));
  return [
    for (final s in out)
      if (s.trim().isNotEmpty) s.trim(),
  ];
}

class _Reader {
  _Reader(this.text, this.line);

  final String text;
  final int line;
  int pos = 0;

  String get rest => text.substring(pos);

  bool get done => rest.trim().isEmpty;

  Match? take(RegExp pattern) {
    final match = pattern.matchAsPrefix(text, pos);
    if (match != null) pos = match.end;
    return match;
  }

  /// The text up to [close], quoted text read whole; past it after.
  String until(String close) {
    var i = pos;
    if (i < text.length && text[i] == '"') {
      final end = text.indexOf('"', i + 1);
      if (end > 0) i = end + 1;
    }
    final at = text.indexOf(close, i);
    if (at < 0) fail('"$close" to close a node');
    final inner = text.substring(pos, at);
    pos = at + close.length;
    return inner;
  }

  Never fail(String wanted) => throw _ParseFailure(
    'Could not read line $line: expected $wanted at "${rest.trim()}".',
  );
}

final _participantLine = RegExp(
  r'^(participant|actor)\s+(\S+)(?:\s+as\s+(.+))?$',
);
final _messageLine = RegExp(
  r'^([^\s:+\-<>()]+)\s*(-->>|->>|-->|->|--x|-x|--\)|-\))\s*[+-]?\s*([^\s:+\-<>()]+)\s*:\s*(.*)$',
);
final _noteLine = RegExp(
  r'^note\s+(over|left of|right of)\s+([^:]+?)\s*:\s*(.*)$',
  caseSensitive: false,
);
const _blockKinds = {'loop', 'alt', 'opt', 'par', 'critical', 'break', 'rect'};

MermaidSequence _parseSequence(Iterable<(int, String)> lines) {
  final participants = <String, MermaidParticipant>{};
  final steps = <MermaidStep>[];
  var autonumber = false;
  var open = 0;

  void see(String id) =>
      participants.putIfAbsent(id, () => MermaidParticipant(id, id));

  for (final (number, line) in lines) {
    final word = line.split(RegExp(r'\s+')).first;
    if (line == 'autonumber') {
      autonumber = true;
      continue;
    }
    if (word == 'activate' || word == 'deactivate' || word == 'title') {
      continue;
    }
    if (_participantLine.firstMatch(line) case final m?) {
      participants[m[2]!] = MermaidParticipant(
        m[2]!,
        _label(m[3] ?? m[2]!),
        actor: m[1] == 'actor',
      );
      continue;
    }
    if (_blockKinds.contains(word)) {
      open++;
      steps.add(MermaidBlockStart(word, line.substring(word.length).trim()));
      continue;
    }
    if (word == 'else' || word == 'and') {
      steps.add(MermaidBlockDivider(line.substring(word.length).trim()));
      continue;
    }
    if (line == 'end') {
      if (open == 0) {
        throw _ParseFailure('Could not read line $number: "end" closes nothing.');
      }
      open--;
      steps.add(const MermaidBlockEnd());
      continue;
    }
    if (_noteLine.firstMatch(line) case final m?) {
      final over = [for (final p in m[2]!.split(',')) p.trim()];
      over.forEach(see);
      final where = m[1]!.toLowerCase();
      steps.add(
        MermaidNote(
          over,
          _label(m[3]!),
          side: where == 'over' ? null : where.split(' ').first,
        ),
      );
      continue;
    }
    if (_messageLine.firstMatch(line) case final m?) {
      see(m[1]!);
      see(m[3]!);
      final arrow = m[2]!;
      steps.add(
        MermaidMessage(
          from: m[1]!,
          to: m[3]!,
          text: _label(m[4]!),
          dashed: arrow.startsWith('--'),
          end: arrow.endsWith('>>')
              ? MermaidMessageEnd.arrow
              : arrow.endsWith('x')
              ? MermaidMessageEnd.cross
              : arrow.endsWith(')')
              ? MermaidMessageEnd.async
              : MermaidMessageEnd.open,
        ),
      );
      continue;
    }
    throw _ParseFailure('Could not read line $number: "$line".');
  }
  if (participants.isEmpty) {
    throw _ParseFailure('The sequence diagram has no participants.');
  }
  for (; open > 0; open--) {
    steps.add(const MermaidBlockEnd());
  }
  return MermaidSequence(
    participants.values.toList(),
    steps,
    autonumber: autonumber,
  );
}
