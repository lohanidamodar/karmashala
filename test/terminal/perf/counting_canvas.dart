import 'dart:ui';

/// A [Canvas] that forwards every call to [inner] while counting invocations
/// per method name.
///
/// The terminal perf harness uses it to get exact, machine-independent draw-op
/// counts: unlike wall-clock timing, an op count is identical on every machine,
/// so it is safe to assert on as a budget.
class CountingCanvas implements Canvas {
  CountingCanvas(this.inner);

  final Canvas inner;

  /// Invocation count keyed by method name.
  final Map<String, int> counts = <String, int>{};

  /// Method names that put something on screen, as opposed to state changes
  /// like save/restore/clip/transform.
  static const drawMembers = <String>{
    'drawRect',
    'drawParagraph',
    'drawLine',
    'drawPath',
    'drawRRect',
    'drawDRRect',
    'drawOval',
    'drawCircle',
    'drawArc',
    'drawImage',
    'drawImageRect',
    'drawImageNine',
    'drawPicture',
    'drawPoints',
    'drawRawPoints',
    'drawVertices',
    'drawAtlas',
    'drawRawAtlas',
    'drawShadow',
    'drawColor',
    'drawPaint',
  };

  /// Total number of draw calls recorded so far.
  int get drawOps {
    var total = 0;
    counts.forEach((name, count) {
      if (drawMembers.contains(name)) total += count;
    });
    return total;
  }

  void reset() => counts.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = _memberName(invocation.memberName);
    counts[name] = (counts[name] ?? 0) + 1;
    return Function.apply(
      _bind(name),
      invocation.positionalArguments,
      invocation.namedArguments,
    );
  }

  /// `Symbol("drawRect")` -> `drawRect`.
  static String _memberName(Symbol symbol) {
    final text = symbol.toString();
    final start = text.indexOf('"');
    final end = text.lastIndexOf('"');
    return start >= 0 && end > start ? text.substring(start + 1, end) : text;
  }

  /// dart:ui's concrete [Canvas] has no forwarding `noSuchMethod`, so calls are
  /// re-dispatched through an explicit binding table. Only the members the
  /// terminal painter and render object actually use are bound; anything else
  /// throws loudly rather than being silently dropped from the recording.
  Function _bind(String name) {
    switch (name) {
      case 'drawRect':
        return inner.drawRect;
      case 'drawParagraph':
        return inner.drawParagraph;
      case 'drawLine':
        return inner.drawLine;
      case 'drawPath':
        return inner.drawPath;
      case 'drawRRect':
        return inner.drawRRect;
      case 'drawCircle':
        return inner.drawCircle;
      case 'drawOval':
        return inner.drawOval;
      case 'drawColor':
        return inner.drawColor;
      case 'drawPaint':
        return inner.drawPaint;
      case 'drawImage':
        return inner.drawImage;
      case 'drawImageRect':
        return inner.drawImageRect;
      case 'save':
        return inner.save;
      case 'saveLayer':
        return inner.saveLayer;
      case 'restore':
        return inner.restore;
      case 'translate':
        return inner.translate;
      case 'scale':
        return inner.scale;
      case 'transform':
        return inner.transform;
      case 'clipRect':
        return inner.clipRect;
      case 'clipRRect':
        return inner.clipRRect;
      case 'clipPath':
        return inner.clipPath;
      default:
        throw UnsupportedError(
          'CountingCanvas has no binding for Canvas.$name — add one so the '
          'call still reaches the real canvas.',
        );
    }
  }
}
