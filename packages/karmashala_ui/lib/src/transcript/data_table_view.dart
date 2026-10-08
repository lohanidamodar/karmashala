import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_icons.dart';
import '../design_tokens.dart';

/// A cell as text: a whole number without `.0`, null as nothing.
String tableCellText(Object? cell) => switch (cell) {
  null => '',
  final double d when d == d.roundToDouble() && d.abs() < 1e15 =>
    d.round().toString(),
  _ => '$cell',
};

/// [columns] and [rows] as RFC 4180 CSV.
String tableToCsv(List<String> columns, List<List<Object?>> rows) {
  String field(Object? cell) {
    final text = tableCellText(cell);
    return text.contains(RegExp(r'[",\r\n]'))
        ? '"${text.replaceAll('"', '""')}"'
        : text;
  }

  return [
    columns.map(field).join(','),
    for (final row in rows) row.map(field).join(','),
  ].join('\n');
}

/// [columns] and [rows] as a Markdown pipe table.
String tableToMarkdown(List<String> columns, List<List<Object?>> rows) {
  String cell(Object? value) => tableCellText(
    value,
  ).replaceAll('|', r'\|').replaceAll(RegExp(r'\r?\n'), '<br>');
  return [
    '| ${columns.map(cell).join(' | ')} |',
    '| ${columns.map((_) => '---').join(' | ')} |',
    for (final row in rows)
      '| ${[for (var c = 0; c < columns.length; c++) cell(c < row.length ? row[c] : null)].join(' | ')} |',
  ].join('\n');
}

/// Orders two cells: numbers (and text that reads as one) by value, other
/// text without regard to case, empty cells last.
int compareTableCells(Object? a, Object? b) {
  final ta = tableCellText(a);
  final tb = tableCellText(b);
  if (ta.isEmpty || tb.isEmpty) {
    return ta.isEmpty == tb.isEmpty ? 0 : (ta.isEmpty ? 1 : -1);
  }
  final na = a is num ? a.toDouble() : double.tryParse(ta);
  final nb = b is num ? b.toDouble() : double.tryParse(tb);
  if (na != null && nb != null) return na.compareTo(nb);
  return ta.toLowerCase().compareTo(tb.toLowerCase());
}

/// Rows under named columns: a header that stays put while the rows scroll
/// under it, sideways scrolling for wide tables, sorting by a tap on a
/// column, and the whole table copied as CSV or Markdown.
class DataTableView extends StatefulWidget {
  const DataTableView({
    required this.columns,
    required this.rows,
    this.maxHeight = 360,
    super.key,
  });

  final List<String> columns;
  final List<List<Object?>> rows;

  /// Past this the rows scroll inside the table, under the header.
  final double maxHeight;

  /// The widest a column is drawn; longer text wraps to three lines.
  static const double maxColumnWidth = 320;

  @override
  State<DataTableView> createState() => _DataTableViewState();
}

class _DataTableViewState extends State<DataTableView> {
  final _sideways = ScrollController();
  int? _sortColumn;
  bool _ascending = true;
  List<List<Object?>>? _sorted;

  @override
  void didUpdateWidget(DataTableView old) {
    super.didUpdateWidget(old);
    if (old.rows != widget.rows || old.columns != widget.columns) {
      _sorted = null;
      if ((_sortColumn ?? 0) >= widget.columns.length) _sortColumn = null;
    }
  }

  @override
  void dispose() {
    _sideways.dispose();
    super.dispose();
  }

  void _sortBy(int column) => setState(() {
    if (_sortColumn != column) {
      _sortColumn = column;
      _ascending = true;
    } else if (_ascending) {
      _ascending = false;
    } else {
      _sortColumn = null;
    }
    _sorted = null;
  });

  List<List<Object?>> get _rows {
    final column = _sortColumn;
    if (column == null) return widget.rows;
    return _sorted ??= [...widget.rows]
      ..sort((a, b) {
        final order = compareTableCells(
          column < a.length ? a[column] : null,
          column < b.length ? b[column] : null,
        );
        // Empty cells stay last whichever way it runs.
        final empty =
            tableCellText(column < a.length ? a[column] : null).isEmpty ||
            tableCellText(column < b.length ? b[column] : null).isEmpty;
        return _ascending || empty ? order : -order;
      });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mono = MonoStyles.small.copyWith(color: scheme.onSurface);
    final head = mono.copyWith(fontWeight: FontWeight.w700);
    final scaler = MediaQuery.textScalerOf(context);
    final columns = widget.columns;
    final rows = _rows;
    final sortIcon = scaler.scale(Chrome.iconSmall) + Insets.xxs;
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final widths = [
      for (var c = 0; c < columns.length; c++)
        math.min(
              DataTableView.maxColumnWidth,
              math.max(
                measure(columns[c], head) + sortIcon,
                widget.rows
                    .take(200)
                    .map((r) => c < r.length ? tableCellText(r[c]) : '')
                    .fold<double>(0, (w, t) => math.max(w, measure(t, mono))),
              ),
            ) +
            Insets.sm * 2,
    ];
    final total = widths.fold<double>(0, (w, c) => w + c);
    final numeric = [
      for (var c = 0; c < columns.length; c++)
        widget.rows.isNotEmpty &&
            widget.rows.every(
              (r) => c >= r.length || r[c] == null || r[c] is num,
            ),
    ];

    Widget cell(int c, String text, TextStyle style) => SizedBox(
      width: widths[c],
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Text(
          text,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: numeric[c] ? TextAlign.right : TextAlign.left,
          style: style,
        ),
      ),
    );

    final header = DecoratedBox(
      key: const ValueKey('table-header'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          for (var c = 0; c < columns.length; c++)
            InkWell(
              key: ValueKey('table-sort-$c'),
              onTap: () => _sortBy(c),
              child: Semantics(
                button: true,
                label:
                    'Sort by ${columns[c]}'
                    '${_sortColumn == c ? (_ascending ? ', ascending' : ', descending') : ''}',
                child: SizedBox(
                  width: widths[c],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.sm,
                      vertical: Insets.xs,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            columns[c],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: numeric[c]
                                ? TextAlign.right
                                : TextAlign.left,
                            style: head,
                          ),
                        ),
                        SizedBox(
                          width: sortIcon,
                          child: _sortColumn == c
                              ? Icon(
                                  _ascending
                                      ? AppIcons.caretUp
                                      : AppIcons.caretDown,
                                  size: Chrome.iconSmall,
                                  color: scheme.primary,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    Widget row(int i) => DecoratedBox(
      decoration: BoxDecoration(
        color: i.isOdd ? StateLayers.subtle(scheme) : null,
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(
              alpha: StateLayers.linkUnderlineAlpha,
            ),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < columns.length; c++)
            cell(c, c < rows[i].length ? tableCellText(rows[i][c]) : '', mono),
        ],
      ),
    );

    // A short table is drawn whole; a long one scrolls under its header.
    const lazyPast = 12;
    final body = rows.length <= lazyPast
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [for (var i = 0; i < rows.length; i++) row(i)],
          )
        : SizedBox(
            height: widget.maxHeight,
            child: ListView.builder(
              key: const ValueKey('table-rows'),
              itemCount: rows.length,
              itemBuilder: (context, i) => row(i),
            ),
          );

    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${rows.length} row${rows.length == 1 ? '' : 's'}',
                  style: muted,
                ),
              ),
              _CopyAs(
                key: const ValueKey('table-copy-csv'),
                label: 'CSV',
                text: () => tableToCsv(columns, rows),
              ),
              _CopyAs(
                key: const ValueKey('table-copy-md'),
                label: 'Markdown',
                text: () => tableToMarkdown(columns, rows),
              ),
            ],
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: LayoutBuilder(
              builder: (context, constraints) => Scrollbar(
                controller: _sideways,
                child: SingleChildScrollView(
                  controller: _sideways,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: math.max(
                      total,
                      constraints.hasBoundedWidth ? constraints.maxWidth : 0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [header, body],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Copy as …": copies what [text] answers and says so for a moment.
class _CopyAs extends StatefulWidget {
  const _CopyAs({required this.label, required this.text, super.key});

  final String label;
  final String Function() text;

  @override
  State<_CopyAs> createState() => _CopyAsState();
}

class _CopyAsState extends State<_CopyAs> {
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text()));
    if (!mounted) return;
    _settle?.cancel();
    setState(() {
      _settle = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final copied = _settle?.isActive ?? false;
    return Tooltip(
      message: 'Copy as ${widget.label}',
      child: TextButton.icon(
        onPressed: _copy,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: Theme.of(context).textTheme.labelSmall,
        ),
        icon: Icon(
          copied ? AppIcons.check : AppIcons.copySimple,
          size: Chrome.iconSmall,
        ),
        label: Text(widget.label),
      ),
    );
  }
}
