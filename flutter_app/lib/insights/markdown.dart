/// The Markdown a chat model writes, as blocks — port of `MarkdownView.parse` (MarkdownView.swift).
sealed class MdBlock {}

class MdHeading extends MdBlock {
  MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  MdParagraph(this.text);
  final String text;
}

class MdBullet extends MdBlock {
  MdBullet(this.indent, this.text);
  final int indent;
  final String text;
}

class MdNumbered extends MdBlock {
  MdNumbered(this.indent, this.number, this.text);
  final int indent;
  final String number;
  final String text;
}

class MdQuote extends MdBlock {
  MdQuote(this.text);
  final String text;
}

class MdCode extends MdBlock {
  MdCode(this.text);
  final String text;
}

class MdTable extends MdBlock {
  MdTable(this.rows);
  final List<List<String>> rows;
}

class MdRule extends MdBlock {}

class MdQuestions extends MdBlock {
  MdQuestions(this.title);
  final String title;
}

List<MdBlock> parseMarkdown(String text) {
  final blocks = <MdBlock>[];
  var paragraph = <String>[];
  List<String>? code;
  var table = <List<String>>[];

  void flushParagraph() {
    final joined = paragraph.join('\n').trim();
    if (joined.isNotEmpty) blocks.add(MdParagraph(joined));
    paragraph = [];
  }

  void flushTable() {
    if (table.isNotEmpty) blocks.add(MdTable(table));
    table = [];
  }

  bool isQuestions(String t) {
    final s = t.replaceAll(RegExp(r'^[ :*]+|[ :*]+$'), '');
    return s == 'שאלות' || s == 'שאלות להמשך' || s == 'שאלות אליך';
  }

  for (final rawLine in text.split('\n')) {
    final line = rawLine.replaceAll('\t', '    ');
    final trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      if (code != null) {
        blocks.add(MdCode(code.join('\n')));
        code = null;
      } else {
        flushParagraph();
        flushTable();
        code = [];
      }
      continue;
    }
    if (code != null) {
      code.add(line);
      continue;
    }

    if (trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.length > 1) {
      flushParagraph();
      final cells = trimmed.substring(1, trimmed.length - 1).split('|').map((c) => c.trim()).toList();
      final separator = cells.every((c) => c.isNotEmpty && RegExp(r'^[-:]+$').hasMatch(c));
      if (!separator) table.add(cells);
      continue;
    }
    flushTable();

    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    final indent = RegExp(r'^ *').stringMatch(line)!.length ~/ 2;

    final compact = trimmed.replaceAll(' ', '');
    if (trimmed.length >= 3 && compact.split('').toSet().length == 1 && '-*_'.contains(trimmed[0])) {
      flushParagraph();
      blocks.add(MdRule());
      continue;
    }

    if (trimmed.startsWith('#')) {
      final level = RegExp(r'^#+').stringMatch(trimmed)!.length;
      final content = trimmed.substring(level).trim();
      if (level <= 6 && content.isNotEmpty) {
        flushParagraph();
        blocks.add(isQuestions(content) ? MdQuestions(content) : MdHeading(level, content));
        continue;
      }
    }

    if (trimmed.length > 1 && '-*•+'.contains(trimmed[0]) && trimmed[1] == ' ') {
      flushParagraph();
      blocks.add(MdBullet(indent, trimmed.substring(2)));
      continue;
    }

    final numbered = RegExp(r'^(\d{1,3})[.)]\s+').firstMatch(trimmed);
    if (numbered != null) {
      flushParagraph();
      blocks.add(MdNumbered(indent, numbered.group(1)!, trimmed.substring(numbered.end)));
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushParagraph();
      blocks.add(MdQuote(trimmed.substring(1).trim()));
      continue;
    }

    // A bold line on its own ("**מה טוב:**") reads as a small heading.
    if (paragraph.isEmpty &&
        trimmed.startsWith('**') &&
        (trimmed.endsWith('**') || trimmed.endsWith('**:') || trimmed.endsWith(':**')) &&
        trimmed.length < 80) {
      final content = trimmed.replaceAll('**', '');
      blocks.add(isQuestions(content) ? MdQuestions(content) : MdHeading(4, content));
      continue;
    }
    if (paragraph.isEmpty && isQuestions(trimmed) && trimmed.length < 30) {
      blocks.add(MdQuestions(trimmed));
      continue;
    }

    paragraph.add(trimmed);
  }
  if (code != null) blocks.add(MdCode(code.join('\n')));
  flushParagraph();
  flushTable();
  return blocks;
}

/// One styled run of inline Markdown.
class MdRun {
  MdRun(this.text, {this.bold = false, this.italic = false, this.code = false});
  final String text;
  final bool bold;
  final bool italic;
  final bool code;
}

/// **bold**, *italic*, `code` and [links](…) — a link shows as its text: answers come from a model, so they aren't opened.
List<MdRun> parseInline(String text) {
  final pattern = RegExp(r'\*\*(.+?)\*\*|__(.+?)__|`([^`]+)`|\*([^*\n]+)\*|\[([^\]]+)\]\([^)]*\)');
  final runs = <MdRun>[];
  var at = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > at) runs.add(MdRun(text.substring(at, m.start)));
    if (m.group(1) != null || m.group(2) != null) {
      runs.add(MdRun(m.group(1) ?? m.group(2)!, bold: true));
    } else if (m.group(3) != null) {
      runs.add(MdRun(m.group(3)!, code: true));
    } else if (m.group(4) != null) {
      runs.add(MdRun(m.group(4)!, italic: true));
    } else {
      runs.add(MdRun(m.group(5)!));
    }
    at = m.end;
  }
  if (at < text.length) runs.add(MdRun(text.substring(at)));
  return runs;
}
