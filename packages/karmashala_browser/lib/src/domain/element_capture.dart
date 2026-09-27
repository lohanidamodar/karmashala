import 'dart:convert';
import 'dart:typed_data';

/// A rectangle in page coordinates (CSS pixels including the scroll offset) —
/// what `Page.captureScreenshot`'s `clip` expects when capturing beyond the
/// viewport, which is how an element taller than the window is captured whole.
class ElementBox {
  const ElementBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  bool get isEmpty => width <= 0 || height <= 0;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  static ElementBox fromJson(Map<String, Object?> json) => ElementBox(
    x: _number(json['x']),
    y: _number(json['y']),
    width: _number(json['width']),
    height: _number(json['height']),
  );

  static double _number(Object? value) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? 0,
    _ => 0,
  };

  @override
  String toString() =>
      '${width.round()}x${height.round()} at (${x.round()}, ${y.round()})';
}

/// The computed properties worth putting in front of an agent: Chrome reports
/// ~340 longhands and pasting all of them buries the useful ones. The full map
/// is still on [ElementCapture.computedStyles].
const List<String> kPromptStyleProperties = [
  'display',
  'position',
  'top',
  'right',
  'bottom',
  'left',
  'width',
  'height',
  'margin',
  'padding',
  'flex-direction',
  'justify-content',
  'align-items',
  'gap',
  'grid-template-columns',
  'color',
  'background-color',
  'border',
  'border-radius',
  'box-shadow',
  'opacity',
  'font-family',
  'font-size',
  'font-weight',
  'line-height',
  'letter-spacing',
  'text-align',
  'text-transform',
  'overflow',
  'z-index',
];

/// Everything captured about one element — the unit that goes into a prompt.
class ElementCapture {
  const ElementCapture({
    required this.selector,
    required this.tagName,
    required this.outerHtml,
    required this.computedStyles,
    required this.box,
    required this.pageUrl,
    required this.pageTitle,
    required this.capturedAt,
    this.elementId,
    this.classNames = const [],
    this.screenshotPng,
  });

  /// A CSS selector that resolves to this element, when one could be derived.
  final String selector;
  final String tagName;
  final String? elementId;
  final List<String> classNames;
  final String outerHtml;

  /// Every computed longhand property Chrome reported.
  final Map<String, String> computedStyles;
  final ElementBox box;
  final String pageUrl;
  final String pageTitle;
  final DateTime capturedAt;

  /// PNG bytes cropped to [box], or null when the element had no area to
  /// capture (a zero-sized or `display: none` node).
  final Uint8List? screenshotPng;

  /// A short human label, e.g. `button#submit.primary`.
  String get description {
    final buffer = StringBuffer(tagName);
    if (elementId != null && elementId!.isNotEmpty) buffer.write('#$elementId');
    for (final className in classNames.take(3)) {
      buffer.write('.$className');
    }
    return buffer.toString();
  }

  /// The curated subset of [computedStyles], in [kPromptStyleProperties] order.
  Map<String, String> get promptStyles => {
    for (final property in kPromptStyleProperties)
      if (computedStyles[property] case final value?
          when value.isNotEmpty && value != 'none' && value != 'normal')
        property: value,
  };

  /// Markdown suitable for pasting straight into an agent prompt.
  String toPromptText({int maxHtmlChars = 4000}) {
    final html = outerHtml.length > maxHtmlChars
        ? '${outerHtml.substring(0, maxHtmlChars)}\n<!-- truncated -->'
        : outerHtml;
    final styles = promptStyles.entries
        .map((entry) => '${entry.key}: ${entry.value};')
        .join('\n');
    final shot = screenshotPng == null
        ? 'Screenshot: none (element has no rendered area)'
        : 'Screenshot: ${screenshotPng!.length} bytes of PNG, cropped to '
              '$box';
    return '''
### $description on $pageUrl

Selector: `$selector`
Box: $box

```html
$html
```

Computed styles:

```css
$styles
```

$shot''';
  }

  /// Structured form; the screenshot is base64 so a capture stays one JSON value.
  Map<String, Object?> toJson({bool includeScreenshot = true}) => {
    'selector': selector,
    'tagName': tagName,
    if (elementId != null) 'id': elementId,
    if (classNames.isNotEmpty) 'classNames': classNames,
    'outerHtml': outerHtml,
    'computedStyles': computedStyles,
    'promptStyles': promptStyles,
    'box': box.toJson(),
    'pageUrl': pageUrl,
    'pageTitle': pageTitle,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    if (includeScreenshot && screenshotPng != null)
      'screenshotPngBase64': base64Encode(screenshotPng!),
  };

  /// [toJson]'s inverse, for a capture that crossed a wire.
  static ElementCapture fromJson(Map<String, Object?> json) {
    final shot = json['screenshotPngBase64'];
    return ElementCapture(
      selector: json['selector']! as String,
      tagName: json['tagName']! as String,
      elementId: json['id'] as String?,
      classNames: [
        for (final name in json['classNames'] as List? ?? const []) '$name',
      ],
      outerHtml: json['outerHtml'] as String? ?? '',
      computedStyles: {
        for (final entry
            in ((json['computedStyles'] as Map?) ?? const {}).entries)
          '${entry.key}': '${entry.value}',
      },
      box: ElementBox.fromJson(
        ((json['box'] as Map?) ?? const {}).cast<String, Object?>(),
      ),
      pageUrl: json['pageUrl'] as String? ?? '',
      pageTitle: json['pageTitle'] as String? ?? '',
      capturedAt: DateTime.parse(json['capturedAt']! as String),
      screenshotPng: shot is String ? base64Decode(shot) : null,
    );
  }
}
