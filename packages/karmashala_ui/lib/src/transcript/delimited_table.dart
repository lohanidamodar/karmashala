import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Rows a table draws; past it a line says how many more there are.
const int kDelimitedTableRows = 200;

/// [text] split into rows of cells by [separator], honouring double-quoted
/// cells (RFC 4180): a separator, a newline or `""` inside quotes is text.
List<List<String>> parseDelimited(String text, {String separator = ','}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  var i = 0;
  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"' && cell.isEmpty) {
      quoted = true;
    } else if (c == separator) {
      endCell();
    } else if (c == '\n') {
      endRow();
    } else if (c != '\r') {
      cell.write(c);
    }
    i++;
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

/// Rows of cells as a table, the first row as its header. Scrolls sideways
/// inside its own box, never the page.
class DelimitedTable extends StatelessWidget {
  const DelimitedTable(this.rows, {super.key});

  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
    final shown = rows.take(kDelimitedTableRows + 1).toList();
    final mono = MonoStyles.small.copyWith(color: scheme.onSurface);
    TableRow line(List<String> cells, {bool header = false}) => TableRow(
      decoration: header
          ? BoxDecoration(color: scheme.surfaceContainerHigh)
          : null,
      children: [
        for (var c = 0; c < width; c++)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            child: Text(
              c < cells.length ? cells[c] : '',
              style: header ? mono.copyWith(fontWeight: FontWeight.w700) : mono,
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: scheme.outlineVariant),
            children: [
              line(shown.first, header: true),
              for (final r in shown.skip(1)) line(r),
            ],
          ),
        ),
        if (rows.length > shown.length)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              '${rows.length - shown.length} more rows not shown',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
