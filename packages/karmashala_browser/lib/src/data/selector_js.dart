/// JavaScript that derives a CSS selector for an element and verifies it, so
/// there is one definition of "a selector for this element": null unless
/// `querySelector` resolves it back to the same node. A selector that points
/// elsewhere is worse than none — the caller acts on the wrong element.
const String kUniqueSelectorJs = r'''
  function unique(el) {
    if (!el || el.nodeType !== 1) return null;
    var esc = (window.CSS && CSS.escape)
      ? function (s) { return CSS.escape(s); }
      : function (s) { return s; };
    var parts = [];
    var node = el;
    while (node && node.nodeType === 1) {
      if (node.id) {
        var byId = '#' + esc(node.id);
        try {
          if (document.querySelectorAll(byId).length === 1) {
            parts.unshift(byId);
            node = null;
            break;
          }
        } catch (err) { /* invalid id, fall through to the structural path */ }
      }
      var part = node.tagName.toLowerCase();
      var parent = node.parentElement;
      if (parent) {
        var same = 0, index = 0;
        for (var i = 0; i < parent.children.length; i++) {
          var child = parent.children[i];
          if (child.tagName === node.tagName) {
            same++;
            if (child === node) index = same;
          }
        }
        if (same > 1) part += ':nth-of-type(' + index + ')';
      }
      parts.unshift(part);
      node = parent;
    }
    var selector = parts.join(' > ');
    if (!selector) return null;
    try {
      return document.querySelector(selector) === el ? selector : null;
    } catch (err) { return null; }
  }
''';
