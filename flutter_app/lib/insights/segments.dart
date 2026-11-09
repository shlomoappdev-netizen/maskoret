import 'dart:convert';

import '../data/fmt.dart';
import 'ai_actions.dart';

/// A chart the model asks to draw — port of `ChartSpec` (Insights.swift):
/// ```chart
/// {"type":"bar","title":"...","data":[{"label":"אוכל","value":420}]}
/// ```
class ChartPoint {
  ChartPoint(this.label, this.value);
  final String label;
  final double value;

  /// Accepts a value written as text too ("1,234", "₪420"); null when it can't be read.
  static ChartPoint? parse(dynamic j) {
    if (j is! Map) return null;
    final l = j['label'];
    final label = l is String ? l : (l is num ? Fmt.number(l.toDouble()) : '');
    final v = j['value'];
    if (v is num) return ChartPoint(label, v.toDouble());
    if (v is! String) return null;
    var cleaned = v.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.endsWith('.')) cleaned = cleaned.substring(0, cleaned.length - 1);
    final number = double.tryParse(cleaned);
    return number == null ? null : ChartPoint(label, number);
  }
}

class ChartSpec {
  ChartSpec(this.type, this.title, this.data);
  final String type;
  final String? title;
  final List<ChartPoint> data;
}

sealed class InsightSegment {}

class TextSegment extends InsightSegment {
  TextSegment(this.text);
  final String text;
}

class ChartSegment extends InsightSegment {
  ChartSegment(this.spec);
  final ChartSpec spec;
}

/// Changes the model proposes, applied only after the user approves them (see ai_actions.dart).
class ActionsSegment extends InsightSegment {
  ActionsSegment(this.plan, this.raw);
  final AIActionPlan plan;
  final String raw;
}

class BrokenSegment extends InsightSegment {
  BrokenSegment(this.text);
  final String text;
}

/// Splits a reply into text, ```chart and ```actions blocks; leaves out the model's thinking.
class InsightParser {
  /// The tags reasoning models wrap their thinking in (Gemini: `<thought>`, others: `<think>` / `<thinking>`).
  static const thinkingTags = ['think', 'thinking', 'thought'];

  /// The reply without the model's thinking; an unfinished thinking section (still streaming) is removed to the end.
  static String withoutThinking(String raw) {
    var text = raw;
    for (final tag in thinkingTags) {
      final open = RegExp('<$tag>', caseSensitive: false);
      final close = RegExp('</$tag>', caseSensitive: false);
      while (true) {
        final start = open.firstMatch(text);
        if (start == null) break;
        final end = close.firstMatch(text.substring(start.end));
        text = end != null
            ? text.substring(0, start.start) + text.substring(start.end + end.end)
            : text.substring(0, start.start);
      }
    }
    return text;
  }

  static List<InsightSegment> parse(String raw) {
    final text = withoutThinking(raw);
    final result = <InsightSegment>[];
    var rest = text;
    while (true) {
      final open = rest.indexOf('```');
      if (open < 0) break;
      _appendText(rest.substring(0, open), result);
      final after = rest.substring(open + 3);
      final nl = after.indexOf('\n');
      final lineEnd = nl < 0 ? after.length : nl;
      final language = after.substring(0, lineEnd).trim().toLowerCase();
      final closeAt = after.indexOf('```', lineEnd);
      if (closeAt < 0) {
        // Still streaming (or never closed): hide an unfinished chart, keep anything else as text.
        if (language != 'chart' && language != 'actions') _appendText(rest.substring(open), result);
        rest = '';
        break;
      }
      final body = after.substring(lineEnd, closeAt);
      final spec = language == 'actions' ? null : decodeChart(body);
      if (language == 'actions') {
        final plan = AIActionPlan.decode(body);
        result.add(plan != null ? ActionsSegment(plan, body) : BrokenSegment(body.trim()));
      } else if (spec != null) {
        result.add(ChartSegment(spec));
      } else if (language == 'chart') {
        result.add(BrokenSegment(body.trim()));
      } else {
        // An ordinary code block — the markdown view shows it as code.
        _appendRaw(rest.substring(open, open + 3 + closeAt + 3), result);
      }
      rest = after.substring(closeAt + 3);
    }
    _appendText(rest, result);
    return _merge(result);
  }

  /// Lines a chat website leaves above a code block when the answer is copied by selecting it.
  static const _codeHeaders = {'chart', 'json', 'code', 'copy', 'copy code', 'העתק', 'העתק קוד', 'קוד', 'העתקה', 'הועתק', 'copied!', 'copied'};

  /// Text that may still contain charts without the ``` fences (when the answer was copied by selecting it).
  static void _appendText(String text, List<InsightSegment> result) {
    var rest = text;
    while (true) {
      final found = _findChart(rest);
      if (found == null) break;
      final lines = rest.substring(0, found.$1).split('\n');
      while (lines.isNotEmpty) {
        final t = lines.last.trim().toLowerCase();
        if (t.isEmpty || _codeHeaders.contains(t)) {
          lines.removeLast();
        } else {
          break;
        }
      }
      _appendRaw(lines.join('\n'), result);
      result.add(ChartSegment(found.$3));
      rest = rest.substring(found.$2);
    }
    _appendRaw(rest, result);
  }

  static void _appendRaw(String text, List<InsightSegment> result) {
    final t = text.trim();
    if (t.isNotEmpty) result.add(TextSegment(t));
  }

  /// Neighbouring text pieces become one, so the markdown (lists, tables) isn't cut in the middle.
  static List<InsightSegment> _merge(List<InsightSegment> segments) {
    final out = <InsightSegment>[];
    for (final s in segments) {
      final last = out.lastOrNull;
      if (s is TextSegment && last is TextSegment) {
        out[out.length - 1] = TextSegment('${last.text}\n\n${s.text}');
      } else {
        out.add(s);
      }
    }
    return out;
  }

  /// The first `{ … }` in the text that is a chart: (start, end, chart).
  static (int, int, ChartSpec)? _findChart(String text) {
    var from = 0;
    while (true) {
      final open = text.indexOf('{', from);
      if (open < 0) return null;
      final close = _matchingBrace(text, open);
      if (close != null) {
        final candidate = text.substring(open, close + 1);
        if (candidate.contains('data')) {
          final spec = decodeChart(candidate);
          if (spec != null) return (open, close + 1, spec);
        }
      }
      from = open + 1;
    }
  }

  static bool _isQuote(String c) => c == '"' || c == '\u201C' || c == '\u201D' || c == '\u201E';

  static int? _matchingBrace(String text, int open) {
    var depth = 0;
    var inString = false, escaped = false;
    for (var i = open; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (_isQuote(ch)) {
          inString = false;
        }
      } else if (_isQuote(ch)) {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return null;
  }

  /// Reads a chart, forgiving what websites and phones do to the JSON on the way
  /// (curly quotes, a "json" line on top, numbers written as "1,234 ₪").
  static ChartSpec? decodeChart(String raw) {
    var json = raw
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u201E', '"')
        .replaceAll('\u00A0', ' ')
        .trim();
    final brace = json.indexOf('{'), last = json.lastIndexOf('}');
    if (brace >= 0 && brace < last) json = json.substring(brace, last + 1);
    try {
      final j = jsonDecode(json);
      if (j is! Map || j['data'] is! List) return null;
      final points = [for (final p in j['data'] as List) ?ChartPoint.parse(p)];
      if (points.isEmpty) return null;
      final type = j['type'], title = j['title'];
      return ChartSpec(type is String ? type : 'bar', title is String ? title : null, points);
    } catch (_) {
      return null;
    }
  }

  static bool isThinking(String raw) {
    final lower = raw.toLowerCase();
    for (final tag in thinkingTags) {
      final start = lower.lastIndexOf('<$tag>');
      if (start >= 0 && lower.indexOf('</$tag>', start) < 0) return true;
    }
    return false;
  }
}
