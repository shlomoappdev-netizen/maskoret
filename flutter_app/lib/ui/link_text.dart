import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// A web address found in plain text: where it is, and where it leads (http or https only).
typedef FoundLink = ({int start, int end, Uri uri});

// Only the characters a URL may hold, so Hebrew right after an address isn't swallowed into it.
final _linkPattern = RegExp(r"(?:https?://|www\.)[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+", caseSensitive: false);
const _trailing = ".,;:!?)]}'\"";

/// The web links in [text] (Linkified.links in Announcements.swift). "www.x.co.il" leads to https://www.x.co.il;
/// punctuation at the end of a sentence stays out of the link.
List<FoundLink> findLinks(String text) {
  final links = <FoundLink>[];
  for (final m in _linkPattern.allMatches(text)) {
    var end = m.end;
    while (end > m.start && _trailing.contains(text[end - 1])) {
      // Keep a closing bracket that has its opening one inside the link (Wikipedia-style addresses).
      final c = text[end - 1];
      final open = switch (c) { ')' => '(', ']' => '[', '}' => '{', _ => null };
      if (open != null) {
        final inner = text.substring(m.start, end - 1);
        if (open.allMatches(inner).length > c.allMatches(inner).length) break;
      }
      end--;
    }
    final raw = text.substring(m.start, end);
    final uri = Uri.tryParse(raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw);
    if (uri == null || !isWebLink(uri) || uri.host.isEmpty || !uri.host.contains('.')) continue;
    links.add((start: m.start, end: end, uri: uri));
  }
  return links;
}

bool isWebLink(Uri uri) => uri.scheme == 'http' || uri.scheme == 'https';

/// Plain text whose web addresses are tappable links that open in the browser.
class LinkText extends StatefulWidget {
  const LinkText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<LinkText> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  static Future<void> _open(Uri uri) async {
    if (!isWebLink(uri)) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final text = widget.text;
    final links = findLinks(text);
    if (links.isEmpty) return Text(text, style: widget.style);
    final linkStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    final spans = <InlineSpan>[];
    var at = 0;
    for (final l in links) {
      if (l.start > at) spans.add(TextSpan(text: text.substring(at, l.start)));
      final r = TapGestureRecognizer()..onTap = () => _open(l.uri);
      _recognizers.add(r);
      spans.add(TextSpan(
        text: text.substring(l.start, l.end),
        style: linkStyle,
        recognizer: r,
        mouseCursor: SystemMouseCursors.click,
        semanticsLabel: 'קישור: ${text.substring(l.start, l.end)}',
      ));
      at = l.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
