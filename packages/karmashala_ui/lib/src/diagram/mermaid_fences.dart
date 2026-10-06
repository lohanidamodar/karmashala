/// One run of a message: markdown, or the source of a closed ```mermaid
/// fence.
typedef MessageRun = ({bool mermaid, String text});

final _opener = RegExp(r'^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)[^`]*$');

/// [markdown] cut at each closed top-level ```mermaid fence. A fence still
/// open — a message streaming in — stays markdown, so it draws as code until
/// it closes; a mermaid fence inside another fence is that fence's text.
List<MessageRun> splitMermaidFences(String markdown) {
  if (!markdown.contains('mermaid')) return [(mermaid: false, text: markdown)];
  final lines = markdown.split('\n');
  final runs = <MessageRun>[];
  final prose = <String>[];
  var i = 0;
  while (i < lines.length) {
    final open = _opener.firstMatch(lines[i]);
    if (open == null) {
      prose.add(lines[i]);
      i++;
      continue;
    }
    final fence = open[1]!;
    final close = RegExp(
      '^ {0,3}${RegExp.escape(fence[0])}{${fence.length},}\\s*\$',
    );
    var end = i + 1;
    while (end < lines.length && !close.hasMatch(lines[end])) {
      end++;
    }
    final closed = end < lines.length;
    if (open[2]!.toLowerCase() == 'mermaid' && closed) {
      if (prose.isNotEmpty) {
        runs.add((mermaid: false, text: prose.join('\n')));
        prose.clear();
      }
      runs.add((mermaid: true, text: lines.sublist(i + 1, end).join('\n')));
    } else {
      prose.addAll(lines.sublist(i, closed ? end + 1 : end));
    }
    i = closed ? end + 1 : end;
  }
  if (prose.isNotEmpty) runs.add((mermaid: false, text: prose.join('\n')));
  return runs;
}
