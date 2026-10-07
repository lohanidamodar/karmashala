// Round 34, phase 1: three Overview concepts drawn with real widgets and the
// app's tokens over one realistic fixture, for the owner to choose between.
// Under tool/ so `flutter test` never picks it up; run it explicitly from app/:
//
//   flutter test tool/overview_concepts.dart
//
// Images land in build/overview-concepts/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/presentation/agent_logo.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _outDir = 'build/overview-concepts';

// ---------------------------------------------------------------------------
// The fixture: six projects, fifteen sessions in every state.

enum S { needsYou, working, quiet, ready, failed, ended }

/// A stretch of activity, in minutes before now.
typedef Span = ({S s, int from, int to});

typedef Plan = ({int done, int total, String step});
typedef Files = ({int count, int add, int del});
typedef Ask = ({String kind, String what, List<String> options});
typedef Sub = ({String title, S s, String doing});

class Sess {
  const Sess(
    this.id,
    this.title,
    this.project,
    this.agent,
    this.machine,
    this.s, {
    required this.doing,
    this.age = '',
    this.plan,
    this.files,
    this.answer,
    this.ask,
    this.subs = const [],
    this.spans = const [],
    this.background,
  });

  final String id, title, project, agent, machine;
  final S s;

  /// What it is doing now, in words.
  final String doing;
  final String age;
  final Plan? plan;
  final Files? files;
  final String? answer;
  final Ask? ask;
  final List<Sub> subs;
  final List<Span> spans;
  final String? background;
}

List<Span> _sp(List<(S, int, int)> raw) => [
  for (final (s, from, to) in raw) (s: s, from: from, to: to),
];

const _w = S.working, _n = S.needsYou, _r = S.ready, _f = S.failed;

final fixture = <Sess>[
  Sess(
    'ks-34',
    'Round 34 · Overview v3',
    'karmashala',
    AgentIds.claudeCode,
    'Windows',
    S.working,
    doing: 'Writing tests in app/test/features/overview',
    age: '42m',
    plan: (done: 3, total: 7, step: 'Fix the peek\'s last answer'),
    files: (count: 6, add: 214, del: 38),
    answer:
        'The peek waits on a transcript feed that only reads while a chat '
        'is on screen. Switching it to a one-shot read of the last turns.',
    subs: [
      (title: 'Map the send path', s: _r, doing: 'Done · 3 findings'),
      (title: 'Review the peek', s: _w, doing: 'Reading overview_peek.dart'),
    ],
    background: 'flutter test · 4m',
    spans: _sp([(_w, 42, 30), (_n, 30, 27), (_w, 27, 9), (_r, 9, 7), (_w, 7, 0)]),
  ),
  Sess(
    'ks-33',
    'Round 33 · Running tab',
    'karmashala',
    AgentIds.codex,
    'WSL · arch',
    S.needsYou,
    doing: 'Wants to run a PowerShell script',
    age: '6m',
    plan: (done: 5, total: 8, step: 'Probe listening ports in WSL'),
    files: (count: 4, add: 96, del: 20),
    ask: (
      kind: 'approval',
      what: 'Run a PowerShell script: probe listening ports in WSL',
      options: ['Allow', 'Deny'],
    ),
    spans: _sp([(_w, 95, 60), (_r, 60, 52), (_w, 52, 6), (_n, 6, 0)]),
  ),
  Sess(
    'ks-rel',
    'Release 1.34 prep',
    'karmashala',
    AgentIds.claudeCode,
    'Windows',
    S.ready,
    doing: 'Finished · waiting for your next message',
    age: '18m',
    plan: (done: 4, total: 4, step: 'Draft the changelog'),
    files: (count: 3, add: 40, del: 12),
    answer:
        '**Version bumped to 1.34.0** and the changelog drafted. The release '
        'notes are in `CHANGELOG.md`; ready for you to tag.',
    spans: _sp([(_w, 70, 18), (_r, 18, 0)]),
  ),
  Sess(
    'beej-tpl',
    'Scaffold templates v3',
    'beej',
    AgentIds.codex,
    'WSL · arch',
    S.working,
    doing: 'Rewriting lib/templates/app.dart',
    age: '1h 10m',
    plan: (done: 2, total: 5, step: 'Port the router template'),
    files: (count: 9, add: 380, del: 121),
    subs: [
      (title: 'Check the web template', s: _w, doing: 'Running dart analyze'),
      (title: 'Check the CLI template', s: _r, doing: 'Done · no issues'),
      (title: 'Golden tests', s: _f, doing: 'Failed · 2 goldens differ'),
    ],
    spans: _sp([(_w, 120, 88), (_n, 88, 80), (_w, 80, 0)]),
  ),
  Sess(
    'beej-ci',
    'CI matrix for macOS',
    'beej',
    AgentIds.claudeCode,
    'build-box',
    S.needsYou,
    doing: 'Asks which Xcode the matrix pins',
    age: '11m',
    plan: (done: 1, total: 4, step: 'Pin the toolchain'),
    ask: (
      kind: 'question',
      what: 'Which Xcode should the macOS matrix pin?',
      options: ['16.4 (stable)', '26 beta', 'Both'],
    ),
    spans: _sp([(_w, 34, 11), (_n, 11, 0)]),
  ),
  Sess(
    'store-rev',
    'Reply to Play reviews',
    'store-console',
    AgentIds.antigravity,
    'Windows',
    S.failed,
    doing: 'Stopped: usage limit reached · resets 14:00',
    age: '25m',
    plan: (done: 6, total: 12, step: 'Draft replies to one-star reviews'),
    spans: _sp([(_w, 80, 25), (_f, 25, 0)]),
  ),
  Sess(
    'store-shots',
    'Listing screenshots',
    'store-console',
    AgentIds.antigravity,
    'Windows',
    S.ready,
    doing: 'Finished · 8 screenshots framed',
    age: '1h',
    files: (count: 8, add: 8, del: 0),
    answer: 'Framed **8 screenshots** for phone and tablet.',
    spans: _sp([(_w, 105, 60), (_r, 60, 0)]),
  ),
  Sess(
    'relay-load',
    'Load test 10k clients',
    'relay',
    AgentIds.claudeCode,
    'build-box',
    S.working,
    doing: 'Running a load test · 7m',
    age: '50m',
    plan: (done: 4, total: 6, step: 'Ramp to 10k connections'),
    background: 'k6 run load.js · 7m',
    spans: _sp([(_w, 50, 0)]),
  ),
  Sess(
    'relay-tls',
    'Rotate TLS certs',
    'relay',
    AgentIds.claudeCode,
    'build-box',
    S.quiet,
    doing: 'Nothing new for 12m · last: waiting for certbot',
    age: '12m',
    plan: (done: 2, total: 3, step: 'Reload the proxy'),
    spans: _sp([(_w, 40, 12)]),
  ),
  Sess(
    'web-blog',
    'Blog: open-sourcing Karmashala',
    'popupbits.com',
    AgentIds.antigravity,
    'Windows',
    S.working,
    doing: 'Drafting the "Why open source" section',
    age: '22m',
    files: (count: 2, add: 140, del: 4),
    spans: _sp([(_w, 22, 0)]),
  ),
  Sess(
    'web-seo',
    'Sitemap and meta tags',
    'popupbits.com',
    AgentIds.claudeCode,
    'Windows',
    S.ended,
    doing: 'Ended 1h ago',
    age: '1h',
    files: (count: 5, add: 61, del: 9),
    spans: _sp([(_w, 110, 75), (_r, 75, 60)]),
  ),
  Sess(
    'docs-api',
    'API reference regen',
    'docs',
    AgentIds.codex,
    'WSL · arch',
    S.ready,
    doing: 'Finished · 42 pages regenerated',
    age: '9m',
    files: (count: 42, add: 1200, del: 980),
    answer: 'Regenerated **42 pages**; two endpoints lost their examples.',
    spans: _sp([(_w, 30, 9), (_r, 9, 0)]),
  ),
  Sess(
    'docs-search',
    'Docs search index',
    'docs',
    AgentIds.claudeCode,
    'Windows',
    S.working,
    doing: 'Reading docs/guide/*.md',
    age: '4m',
    plan: (done: 1, total: 3, step: 'Collect the headings'),
    spans: _sp([(_w, 4, 0)]),
  ),
  Sess(
    'ks-29',
    'Round 29 · forks',
    'karmashala',
    AgentIds.claudeCode,
    'Windows',
    S.ended,
    doing: 'Ended 2h ago · merged',
    age: '2h',
    spans: _sp([(_w, 120, 100)]),
  ),
  Sess(
    'beej-readme',
    'README pass',
    'beej',
    AgentIds.claudeCode,
    'Windows',
    S.ended,
    doing: 'Ended 3h ago',
    age: '3h',
  ),
];

const projects = [
  'karmashala',
  'beej',
  'store-console',
  'relay',
  'popupbits.com',
  'docs',
];

bool _live(Sess s) => s.s != S.ended;

// ---------------------------------------------------------------------------
// Shared pieces.

Color? stateColor(BuildContext context, S s) {
  final c = SemanticColors.of(context);
  return switch (s) {
    S.needsYou => c.attention,
    S.working => c.working,
    S.ready => c.idle,
    S.failed => c.failure,
    S.quiet || S.ended => null,
  };
}

String stateLabel(S s) => switch (s) {
  S.needsYou => 'Needs you',
  S.working => 'Working',
  S.quiet => 'Quiet',
  S.ready => 'Ready',
  S.failed => 'Failed',
  S.ended => 'Done',
};

class StateGlyph extends StatelessWidget {
  const StateGlyph(this.sess, {this.size = 14, super.key});

  final Sess sess;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = stateColor(context, sess.s);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return switch (sess.s) {
      S.needsYou => NeedsYouGlyph(
        size: size,
        question: sess.ask?.kind == 'question',
      ),
      S.working => WorkingSpinner(size: size, color: color!),
      S.failed => Icon(AppIcons.xCircle, size: size, color: color),
      S.ready => Icon(AppIcons.checkCircle, size: size, color: color),
      S.quiet => Icon(AppIcons.pauseCircle, size: size, color: muted),
      S.ended => Icon(AppIcons.checkCircle, size: size, color: muted),
    };
  }
}

/// The agent's logo in a ring of its state.
class AgentDot extends StatelessWidget {
  const AgentDot(this.sess, {this.size = 28, super.key});

  final Sess sess;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ring = stateColor(context, sess.s) ?? scheme.outlineVariant;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHigh,
        border: Border.all(color: ring, width: 2),
      ),
      alignment: Alignment.center,
      child: AgentLogo(
        agentId: sess.agent,
        size: size * 0.5,
        color: scheme.onSurface,
      ),
    );
  }
}

/// Last [window] minutes as bands, now at the right.
class ActivityStrip extends StatelessWidget {
  const ActivityStrip(
    this.spans, {
    this.window = 120,
    this.height = 14,
    this.ticks = false,
    super.key,
  });

  final List<Span> spans;
  final int window;
  final double height;
  final bool ticks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Activity, last ${window ~/ 60} hours',
      child: SizedBox(
        height: height,
        child: CustomPaint(
          size: Size.infinite,
          painter: _StripPainter(
            spans: spans,
            window: window,
            track: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            now: scheme.onSurface,
            colorOf: (s) =>
                stateColor(context, s) ?? scheme.outline.withValues(alpha: .5),
            ticks: ticks,
            tick: scheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.spans,
    required this.window,
    required this.track,
    required this.now,
    required this.colorOf,
    required this.ticks,
    required this.tick,
  });

  final List<Span> spans;
  final int window;
  final Color track, now, tick;
  final Color Function(S) colorOf;
  final bool ticks;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = track,
    );
    double x(int minutesAgo) =>
        size.width * (1 - minutesAgo.clamp(0, window) / window);
    for (final span in spans) {
      final rect = Rect.fromLTRB(x(span.from), 0, x(span.to), size.height);
      if (rect.width <= 0) continue;
      final paint = Paint()
        ..color = span.s == S.ready
            ? colorOf(span.s).withValues(alpha: .45)
            : colorOf(span.s);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, r), paint);
    }
    if (ticks) {
      for (var m = 30; m < window; m += 30) {
        canvas.drawLine(
          Offset(x(m), 0),
          Offset(x(m), size.height),
          Paint()
            ..color = tick
            ..strokeWidth = 1,
        );
      }
    }
    canvas.drawRect(
      Rect.fromLTWH(size.width - 2, -2, 2, size.height + 4),
      Paint()..color = now,
    );
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) => false;
}

/// One line, Enter sends: the quick message.
class QuickComposer extends StatelessWidget {
  const QuickComposer({
    required this.sess,
    this.dense = false,
    this.filled,
    super.key,
  });

  final Sess sess;
  final bool dense;
  final String? filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hint = switch (sess.s) {
      S.working => 'Message · queues until the turn ends',
      S.needsYou => 'Or reply in words…',
      S.ended => 'Message to resume…',
      _ => 'Message ${sess.title.split(' · ').first}…',
    };
    return Container(
      height: dense ? 30 : 36,
      padding: const EdgeInsets.only(left: Insets.sm, right: Insets.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            AppIcons.chatCircle,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              filled ?? hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: filled == null ? scheme.onSurfaceVariant : null,
              ),
            ),
          ),
          if (!dense)
            Text(
              '↵',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: Insets.xs),
          Icon(
            AppIcons.paperPlaneRight,
            size: 14,
            color: filled == null ? scheme.onSurfaceVariant : scheme.primary,
          ),
        ],
      ),
    );
  }
}

/// The open ask, answerable where it is.
class AskBox extends StatelessWidget {
  const AskBox(this.sess, {this.compact = false, super.key});

  final Sess sess;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ask = sess.ask!;
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final question = ask.kind == 'question';
    return Container(
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: tones.attentionSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: tones.attentionEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              NeedsYouGlyph(size: 13, question: question),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  ask.what,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              for (final (i, o) in ask.options.indexed)
                if (!question && i == 0)
                  FilledButton(
                    style: _small,
                    onPressed: () {},
                    child: Text(o),
                  )
                else
                  OutlinedButton(
                    style: _small,
                    onPressed: () {},
                    child: Text(o),
                  ),
              if (!question && !compact)
                TextButton(
                  style: _small,
                  onPressed: () {},
                  child: const Text('Always for this session'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static final _small = ButtonStyle(
    visualDensity: VisualDensity.compact,
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: Insets.md),
    ),
    minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

class PlanBar extends StatelessWidget {
  const PlanBar(this.plan, {super.key});

  final Plan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final done = plan.done == plan.total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(AppIcons.listChecks, size: 12, color: muted),
            const SizedBox(width: Insets.xs),
            Text(
              '${plan.done}/${plan.total}',
              style: theme.textTheme.labelSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                done ? 'Plan done' : plan.step,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        LinearMeter(
          value: plan.done / plan.total,
          thickness: 4,
          color: done
              ? SemanticColors.of(context).idle
              : SemanticColors.of(context).working,
          semanticsLabel: 'Plan ${plan.done} of ${plan.total}',
        ),
      ],
    );
  }
}

class FilesLine extends StatelessWidget {
  const FilesLine(this.files, {super.key});

  final Files files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = SemanticColors.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          AppIcons.file,
          size: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Insets.xs),
        Text('${files.count} files ', style: style),
        Text('+${files.add}', style: style?.copyWith(color: c.diffAdded)),
        Text(' −${files.del}', style: style?.copyWith(color: c.diffRemoved)),
      ],
    );
  }
}

/// A two-line quote of the last answer, bold runs drawn bold.
class AnswerQuote extends StatelessWidget {
  const AnswerQuote(this.text, {this.lines = 2, super.key});

  final String text;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurface.withValues(alpha: .85),
    );
    final spans = <InlineSpan>[];
    final parts = text.split('**');
    for (final (i, part) in parts.indexed) {
      final code = part.split('`');
      for (final (j, bit) in code.indexed) {
        spans.add(
          TextSpan(
            text: bit,
            style: j.isOdd
                ? base?.copyWith(
                    fontFamily: kMonoFamily,
                    backgroundColor: scheme.surfaceContainerHighest,
                  )
                : i.isOdd
                ? base?.copyWith(fontWeight: FontWeight.w700)
                : base,
          ),
        );
      }
    }
    return Container(
      padding: const EdgeInsets.only(left: Insets.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outlineVariant, width: 2)),
      ),
      child: Text.rich(
        TextSpan(children: spans),
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class SubTree extends StatelessWidget {
  const SubTree(this.subs, {super.key});

  final List<Sub> subs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final sub in subs)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Text(
                  '↳ ',
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
                StateGlyph(
                  Sess('', '', '', '', '', sub.s, doing: ''),
                  size: 11,
                ),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: sub.title,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: '  ${sub.doing}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class StatePill extends StatelessWidget {
  const StatePill(this.sess, {super.key});

  final Sess sess;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        stateColor(context, sess.s) ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        sess.age.isEmpty ? stateLabel(sess.s) : '${stateLabel(sess.s)} · ${sess.age}',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// "▶ Doing now" line with its glyph; muted unless it matters.
class DoingLine extends StatelessWidget {
  const DoingLine(this.sess, {this.maxLines = 1, super.key});

  final Sess sess;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = sess.s == S.needsYou || sess.s == S.failed
        ? stateColor(context, sess.s)
        : theme.colorScheme.onSurface.withValues(alpha: .85);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: StateGlyph(sess, size: 12),
        ),
        const SizedBox(width: Insets.sm),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: sess.doing),
                if (sess.background case final bg?) ...[
                  const TextSpan(text: '   '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Icon(
                      AppIcons.terminal,
                      size: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  TextSpan(
                    text: ' $bg',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// The counters, as a row of state chips.
class Counters extends StatelessWidget {
  const Counters({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    int n(S s) => fixture.where((x) => x.s == s).length;
    Widget chip(S s, int count, String label) {
      final color = stateColor(context, s) ?? theme.colorScheme.onSurfaceVariant;
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? Insets.sm : Insets.md,
          vertical: compact ? Insets.xs : Insets.sm,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: s == S.needsYou
                ? SurfaceTones.of(context).attentionEdge
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StateGlyph(Sess('', '', '', '', '', s, doing: ''), size: 13),
            const SizedBox(width: Insets.sm),
            Text(
              '$count',
              style: (compact
                      ? theme.textTheme.titleSmall
                      : theme.textTheme.titleMedium)
                  ?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: Insets.xs),
            Text(label, style: theme.textTheme.labelMedium),
          ],
        ),
      );
    }

    return Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.sm,
      children: [
        chip(S.needsYou, n(S.needsYou), 'need you'),
        chip(S.working, n(S.working), 'working'),
        chip(S.ready, n(S.ready), 'ready'),
        chip(S.failed, n(S.failed), 'failed'),
        chip(S.ended, n(S.ended), 'done today'),
      ],
    );
  }
}

class Legend extends StatelessWidget {
  const Legend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget key(S s, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: s == S.ready
                ? stateColor(context, s)!.withValues(alpha: .45)
                : stateColor(context, s),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: Insets.xs),
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(width: Insets.md),
      ],
    );
    return Wrap(
      children: [
        key(S.working, 'working'),
        key(S.needsYou, 'waiting on you'),
        key(S.ready, 'finished, idle'),
        key(S.failed, 'failed'),
      ],
    );
  }
}

TextStyle? _muted(BuildContext c) => Theme.of(
  c,
).textTheme.labelSmall?.copyWith(color: Theme.of(c).colorScheme.onSurfaceVariant);

Widget _projectHeader(BuildContext context, String name) {
  final theme = Theme.of(context);
  final live = fixture.where((s) => s.project == name && _live(s)).toList();
  return Padding(
    padding: const EdgeInsets.only(top: Insets.lg, bottom: Insets.sm),
    child: Row(
      children: [
        Text(
          name,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: Insets.sm),
        Text(
          '${live.length} live',
          style: _muted(context),
        ),
      ],
    ),
  );
}

Widget _topBar(BuildContext context, {required String concept}) {
  final theme = Theme.of(context);
  return Row(
    children: [
      Icon(AppIcons.squaresFour, color: theme.colorScheme.tertiary),
      const SizedBox(width: Insets.sm),
      Text('Overview', style: theme.textTheme.titleMedium),
      const SizedBox(width: Insets.md),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(concept, style: theme.textTheme.labelSmall),
      ),
      const Spacer(),
      Icon(AppIcons.funnel, size: 16, color: theme.colorScheme.onSurfaceVariant),
    ],
  );
}

// ---------------------------------------------------------------------------
// Concept A: live activity strips.

class ConceptA extends StatelessWidget {
  const ConceptA({required this.phone, super.key});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = phone ? Insets.lg : Insets.xl;
    final rows = <Widget>[];
    for (final project in projects) {
      final sessions = fixture.where((s) => s.project == project).toList();
      if (sessions.isEmpty) continue;
      rows.add(_projectHeader(context, project));
      for (final s in sessions) {
        rows.add(phone ? _PhoneStripRow(s) : _StripRow(s));
      }
    }
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: ListView(
        padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xl),
        children: [
          _topBar(context, concept: 'A · Live activity strips'),
          const SizedBox(height: Insets.md),
          Counters(compact: phone),
          const SizedBox(height: Insets.md),
          if (!phone)
            Row(
              children: [
                const SizedBox(width: 560),
                const Expanded(child: _Axis()),
                const SizedBox(width: 300),
              ],
            )
          else
            const Legend(),
          ...rows,
          if (!phone) ...[
            const SizedBox(height: Insets.md),
            const Legend(),
          ],
        ],
      ),
    );
  }
}

class _Axis extends StatelessWidget {
  const _Axis();

  @override
  Widget build(BuildContext context) {
    final style = _muted(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('2h ago', style: style),
        Text('90m', style: style),
        Text('1h', style: style),
        Text('30m', style: style),
        Text('now', style: style?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _StripRow extends StatelessWidget {
  const _StripRow(this.s);

  final Sess s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ended = s.s == S.ended;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: Insets.sm),
      child: Row(
        children: [
          AgentDot(s, size: 26),
          const SizedBox(width: Insets.md),
          SizedBox(
            width: 200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: ended ? scheme.onSurfaceVariant : null,
                  ),
                ),
                Text(
                  '${s.machine}${s.subs.isEmpty ? '' : ' · ↳ ${s.subs.length}'}',
                  style: _muted(context),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          SizedBox(
            width: 290,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DoingLine(s),
                if (s.plan case final plan? when s.s != S.ended)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 20),
                    child: Text(
                      'step ${plan.done + (plan.done < plan.total ? 1 : 0)}/${plan.total} · ${plan.step}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _muted(context),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          Expanded(child: ActivityStrip(s.spans, height: 16, ticks: true)),
          const SizedBox(width: Insets.md),
          SizedBox(
            width: 70,
            child: s.files == null
                ? const SizedBox()
                : Text(
                    '+${s.files!.add} −${s.files!.del}',
                    style: _muted(context),
                  ),
          ),
          SizedBox(width: 220, child: QuickComposer(sess: s, dense: true)),
        ],
      ),
    );
    if (s.ask == null) return row;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: SurfaceTones.of(context).attentionSurface.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        children: [
          row,
          Padding(
            padding: const EdgeInsets.fromLTRB(250, 0, 300, Insets.sm),
            child: AskBox(s),
          ),
        ],
      ),
    );
  }
}

class _PhoneStripRow extends StatelessWidget {
  const _PhoneStripRow(this.s);

  final Sess s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (s.s == S.ended) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            AgentDot(s, size: 22),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                s.title,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(s.age, style: _muted(context)),
          ],
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: s.ask != null
            ? SurfaceTones.of(context).attentionSurface.withValues(alpha: .5)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AgentDot(s, size: 24),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              StatePill(s),
            ],
          ),
          const SizedBox(height: Insets.sm),
          DoingLine(s),
          const SizedBox(height: Insets.sm),
          ActivityStrip(s.spans, height: 12, window: 60),
          if (s.ask != null) ...[
            const SizedBox(height: Insets.sm),
            AskBox(s, compact: true),
          ],
          const SizedBox(height: Insets.sm),
          QuickComposer(sess: s, dense: true),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Concept B: rich session cards.

class ConceptB extends StatelessWidget {
  const ConceptB({required this.phone, super.key});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = phone ? Insets.lg : Insets.xl;
    final live = fixture.where(_live).toList()
      ..sort((a, b) => _rank(a.s).compareTo(_rank(b.s)));
    final ended = fixture.where((s) => !_live(s)).toList();
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: ListView(
        padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xl),
        children: [
          _topBar(context, concept: 'B · Rich session cards'),
          const SizedBox(height: Insets.md),
          Counters(compact: phone),
          const SizedBox(height: Insets.lg),
          if (phone)
            for (final s in live)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: IntrinsicHeight(child: RichCard(s)),
              )
          else
            ..._grid([for (final s in live) RichCard(s)], 4, Insets.md),
          const SizedBox(height: Insets.sm),
          Text(
            '${ended.length} done today ▸',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

int _rank(S s) => switch (s) {
  S.needsYou => 0,
  S.failed => 1,
  S.working => 2,
  S.quiet => 3,
  S.ready => 4,
  S.ended => 5,
};

List<Widget> _grid(List<Widget> tiles, int across, double gap) => [
  for (var start = 0; start < tiles.length; start += across)
    Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = start; i < start + across; i++) ...[
              if (i > start) SizedBox(width: gap),
              Expanded(
                child: i < tiles.length ? tiles[i] : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
    ),
];

class RichCard extends StatelessWidget {
  const RichCard(this.s, {super.key});

  final Sess s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final needs = s.s == S.needsYou;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: needs
              ? SurfaceTones.of(context).attentionEdge
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AgentDot(s, size: 30),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${s.project} · ${s.machine}',
                      maxLines: 1,
                      style: _muted(context),
                    ),
                  ],
                ),
              ),
              StatePill(s),
            ],
          ),
          const SizedBox(height: Insets.md),
          DoingLine(s, maxLines: 2),
          if (s.plan case final plan?) ...[
            const SizedBox(height: Insets.sm),
            PlanBar(plan),
          ],
          if (s.ask != null) ...[
            const SizedBox(height: Insets.sm),
            AskBox(s, compact: true),
          ] else if (s.answer case final answer?) ...[
            const SizedBox(height: Insets.sm),
            AnswerQuote(answer),
          ],
          if (s.subs.isNotEmpty) ...[
            const SizedBox(height: Insets.sm),
            SubTree(s.subs),
          ],
          const Spacer(),
          const SizedBox(height: Insets.sm),
          Row(
            children: [
              if (s.files case final files?) FilesLine(files),
              const Spacer(),
              SizedBox(
                width: 90,
                child: Sparkline(
                  values: _spark(s.spans),
                  color: stateColor(context, s.s) ?? scheme.outline,
                  height: 16,
                  semanticsLabel: 'activity',
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          QuickComposer(sess: s, dense: true),
        ],
      ),
    );
  }
}

/// Minutes working per 10-minute bucket over the last two hours.
List<double> _spark(List<Span> spans) => [
  for (var b = 120; b > 0; b -= 10)
    [
      for (final sp in spans)
        if (sp.s == S.working)
          (sp.from.clamp(b - 10, b) - sp.to.clamp(b - 10, b)).toDouble(),
    ].fold(0.0, (a, b) => a + b),
];

// ---------------------------------------------------------------------------
// Concept C: hybrid — the fleet's heartbeat, a needs-you queue, and compact
// cards each carrying its own strip.

class ConceptC extends StatelessWidget {
  const ConceptC({required this.phone, super.key});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = phone ? Insets.lg : Insets.xl;
    final asks = fixture.where((s) => s.s == S.needsYou || s.s == S.failed);
    final rest = fixture.where(
      (s) => _live(s) && s.s != S.needsYou && s.s != S.failed,
    );
    final queue = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EyebrowLabel(
          'Waiting on you · ${asks.length}',
          padding: const EdgeInsets.only(bottom: Insets.sm),
        ),
        for (final s in asks)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: _QueueCard(s),
          ),
      ],
    );
    final byProject = <Widget>[];
    if (!phone) {
      byProject.add(const SizedBox(height: Insets.sm));
      byProject.addAll(
        _grid([
          for (final project in projects)
            for (final s in rest.where((s) => s.project == project))
              CompactCard(s),
        ], 3, Insets.sm),
      );
    }
    for (final project in phone ? projects : const <String>[]) {
      final sessions = rest.where((s) => s.project == project).toList();
      if (sessions.isEmpty) continue;
      byProject.add(_projectHeader(context, project));
      if (phone) {
        for (final s in sessions) {
          byProject.add(
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: CompactCard(s),
            ),
          );
        }
      } else {
        byProject.addAll(
          _grid([for (final s in sessions) CompactCard(s)], 3, Insets.sm),
        );
      }
    }
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: ListView(
        padding: EdgeInsets.fromLTRB(gutter, Insets.md, gutter, Insets.xl),
        children: [
          _topBar(context, concept: 'C · Hybrid'),
          const SizedBox(height: Insets.md),
          _Heartbeat(phone: phone),
          const SizedBox(height: Insets.lg),
          if (phone) ...[
            queue,
            ...byProject,
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 380, child: queue),
                const SizedBox(width: Insets.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      EyebrowLabel(
                        'At work · ${rest.length}',
                        padding: EdgeInsets.zero,
                      ),
                      ...byProject,
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Stacked count of agents working and waiting, two hours to now.
class _Heartbeat extends StatelessWidget {
  const _Heartbeat({required this.phone});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = SemanticColors.of(context);
    List<double> count(S state) => [
      for (var m = 120; m >= 0; m -= 2)
        fixture
            .where(
              (s) => s.spans.any(
                (sp) => sp.s == state && sp.from >= m && sp.to < m,
              ),
            )
            .length
            .toDouble(),
    ];
    final working = count(S.working);
    final waiting = count(S.needsYou);
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '5 agents working',
                style: TextStyle(color: c.working, fontWeight: FontWeight.w700),
              ),
              const TextSpan(text: ' · '),
              TextSpan(
                text: '2 waiting on you',
                style: TextStyle(
                  color: c.attention,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const TextSpan(text: ' · 3 ready · 1 failed'),
            ],
          ),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 2),
        Text(
          '4h 12m of agent time in the last two hours · 31 files changed',
          style: _muted(context),
        ),
      ],
    );
    final chart = SizedBox(
      height: phone ? 44 : 56,
      child: Stack(
        children: [
          Positioned.fill(
            child: Sparkline(
              values: [
                for (var i = 0; i < working.length; i++)
                  working[i] + waiting[i],
              ],
              secondaryValues: waiting,
              color: c.working,
              secondaryColor: c.attention,
              height: phone ? 44 : 56,
              semanticsLabel: 'Agents at work, last two hours',
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: Insets.sm), chart],
            )
          : Row(
              children: [
                SizedBox(width: 420, child: summary),
                const SizedBox(width: Insets.xl),
                Expanded(
                  child: Column(
                    children: [
                      chart,
                      const SizedBox(height: 2),
                      const _Axis(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard(this.s);

  final Sess s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = s.s == S.failed;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: failed
            ? SemanticColors.of(context).failureSurface
            : SurfaceTones.of(context).attentionSurface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: failed
              ? SemanticColors.of(context).failure.withValues(alpha: .5)
              : SurfaceTones.of(context).attentionEdge,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AgentDot(s, size: 26),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text('${s.project} · ${s.machine}', style: _muted(context)),
                  ],
                ),
              ),
              StatePill(s),
            ],
          ),
          const SizedBox(height: Insets.sm),
          if (s.ask != null)
            AskBox(s)
          else
            DoingLine(s, maxLines: 2),
          if (s.plan case final plan?) ...[
            const SizedBox(height: Insets.sm),
            PlanBar(plan),
          ],
          const SizedBox(height: Insets.sm),
          QuickComposer(
            sess: s,
            dense: true,
            filled: failed ? null : null,
          ),
        ],
      ),
    );
  }
}

class CompactCard extends StatelessWidget {
  const CompactCard(this.s, {super.key});

  final Sess s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AgentDot(s, size: 24),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text('${s.project} · ${s.machine}', style: _muted(context)),
            ],
          ),
          const SizedBox(height: Insets.sm),
          DoingLine(s),
          const SizedBox(height: Insets.sm),
          ActivityStrip(s.spans, height: 10),
          const SizedBox(height: Insets.xs),
          Row(
            children: [
              if (s.plan case final plan?)
                Text(
                  'plan ${plan.done}/${plan.total}',
                  style: _muted(context),
                ),
              if (s.plan != null && s.files != null)
                Text('  ·  ', style: _muted(context)),
              if (s.files case final files?) FilesLine(files),
              if (s.subs.isNotEmpty)
                Text('  ·  ↳ ${s.subs.length}', style: _muted(context)),
              const Spacer(),
              Text('2h', style: _muted(context)),
            ],
          ),
          if (s.answer case final answer? when s.s == S.ready) ...[
            const SizedBox(height: Insets.sm),
            AnswerQuote(answer, lines: 2),
          ],
          const SizedBox(height: Insets.sm),
          QuickComposer(sess: s, dense: true),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Every font the app bundles — without this flutter_test draws boxes.
Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadBundledFonts);

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget Function(bool phone) concept, {
    required Size size,
    Brightness brightness = Brightness.dark,
  }) async {
    final phone = size.width < 600;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final base = brightness == Brightness.dark
        ? AppTheme.dark()
        : AppTheme.light();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentRegistryProvider.overrideWithValue(
            AgentRegistry.withExtra(const []),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            platform: phone ? TargetPlatform.android : TargetPlatform.windows,
          ),
          builder: (context, child) => RepaintBoundary(
            key: key,
            child: UiDensity.wrap(context, child!),
          ),
          home: Scaffold(body: SafeArea(child: concept(phone))),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final render =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    final error = tester.takeException();
    await tester.pumpWidget(const SizedBox());
    expect(error, isNull);
  }

  final concepts = <String, Widget Function(bool)>{
    'A-strips': (phone) => ConceptA(phone: phone),
    'B-cards': (phone) => ConceptB(phone: phone),
    'C-hybrid': (phone) => ConceptC(phone: phone),
  };
  for (final MapEntry(key: name, value: build) in concepts.entries) {
    testWidgets(
      '$name desktop',
      (t) => shoot(t, '$name-1440x900', build, size: const Size(1440, 900)),
    );
    testWidgets(
      '$name phone',
      (t) => shoot(t, '$name-390x844', build, size: const Size(390, 844)),
    );
  }
}
