import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/diagrams.dart';

void main() {
  group('flowchart', () {
    MermaidFlowchart flow(String source) =>
        parseMermaid(source) as MermaidFlowchart;

    test('reads the direction, nodes, shapes and labelled edges', () {
      final chart = flow('''
graph LR
  A[Start] --> B{Is it?}
  B -->|Yes| C(Round)
  B -- No --> D((Circle))
  C -.-> E[(Store)]
  D ==> E
''');
      expect(chart.direction, MermaidDirection.leftRight);
      expect(chart.nodes.map((n) => n.id), ['A', 'B', 'C', 'D', 'E']);
      expect(chart.node('A').label, 'Start');
      expect(chart.node('B').shape, MermaidShape.diamond);
      expect(chart.node('C').shape, MermaidShape.round);
      expect(chart.node('D').shape, MermaidShape.circle);
      expect(chart.node('E').shape, MermaidShape.cylinder);
      expect(chart.edges, hasLength(5));
      expect(chart.edges[1].label, 'Yes');
      expect(chart.edges[2].label, 'No');
      expect(chart.edges[3].line, MermaidLine.dotted);
      expect(chart.edges[4].line, MermaidLine.thick);
      expect(chart.edges.every((e) => e.arrow), isTrue);
    });

    test('flowchart TD is top-down; a bare id is its own label', () {
      final chart = flow('flowchart TD\n  one --- two');
      expect(chart.direction, MermaidDirection.topDown);
      expect(chart.node('one').label, 'one');
      expect(chart.edges.single.arrow, isFalse);
    });

    test('chains, & and semicolons make every edge', () {
      final chart = flow('graph TB; A --> B --> C; A & B --> D');
      expect(
        chart.edges.map((e) => '${e.from}>${e.to}'),
        ['A>B', 'B>C', 'A>D', 'B>D'],
      );
    });

    test('quoted labels, line breaks, comments and styling lines', () {
      final chart = flow('''
graph TD
  %% a comment
  A["Hello, (world)"] --> B["two<br/>lines"]
  subgraph S [Group]
    B --> C
  end
  classDef hot fill:#f00
  class A hot
  style B stroke:#333
  click A "https://example.com"
''');
      expect(chart.node('A').label, 'Hello, (world)');
      expect(chart.node('B').label, 'two\nlines');
      expect(chart.nodes.map((n) => n.id), ['A', 'B', 'C']);
      expect(chart.edges, hasLength(2));
    });

    test('a later bare reference keeps the first label', () {
      final chart = flow('graph TD\n A[Alpha] --> B\n B --> A');
      expect(chart.node('A').label, 'Alpha');
    });

    test('a statement it cannot read is an error naming the line', () {
      final result = parseMermaid('graph TD\n  A --> \n  B[unclosed');
      expect(result, isA<MermaidError>());
      expect((result as MermaidError).reason, contains('line'));
    });
  });

  group('sequence', () {
    test('reads participants, messages, notes and blocks', () {
      final result = parseMermaid('''
sequenceDiagram
  autonumber
  participant A as Alice
  actor B as Bob
  A->>B: Hello
  B-->>A: Hi back
  Note over A,B: they talk
  loop Every minute
    A-)B: ping
  end
  A-xC: lost
''');
      final seq = result as MermaidSequence;
      expect(seq.participants.map((p) => p.label), ['Alice', 'Bob', 'C']);
      expect(seq.participants[1].actor, isTrue);
      expect(seq.autonumber, isTrue);
      final messages = seq.steps.whereType<MermaidMessage>().toList();
      expect(messages.map((m) => m.text), ['Hello', 'Hi back', 'ping', 'lost']);
      expect(messages[1].dashed, isTrue);
      expect(messages[3].end, MermaidMessageEnd.cross);
      final note = seq.steps.whereType<MermaidNote>().single;
      expect(note.over, ['A', 'B']);
      final block = seq.steps.whereType<MermaidBlockStart>().single;
      expect(block.kind, 'loop');
      expect(block.label, 'Every minute');
      expect(seq.steps.whereType<MermaidBlockEnd>(), hasLength(1));
    });
  });

  test('a diagram type not drawn here says which', () {
    final result = parseMermaid('gantt\n  title A plan');
    expect(result, isA<MermaidUnsupported>());
    expect((result as MermaidUnsupported).type, 'gantt');
  });

  test('nothing to draw is an error', () {
    expect(parseMermaid('  \n%% only a comment\n'), isA<MermaidError>());
  });
}
