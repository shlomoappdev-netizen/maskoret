import SwiftUI

/// Renders the Markdown a chat model writes — headings, bullet and numbered lists (nested),
/// bold/italic/code, quotes, code blocks, tables and separators — the way chat apps show it.
struct MarkdownView: View {
    let text: String

    enum Block: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, number: String, text: String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
        case questions(title: String)

        var id: String {
            switch self {
            case .heading(let l, let t): return "h\(l)\(t)"
            case .paragraph(let t): return "p\(t)"
            case .bullet(let i, let t): return "b\(i)\(t)"
            case .numbered(let i, let n, let t): return "n\(i)\(n)\(t)"
            case .quote(let t): return "q\(t)"
            case .code(let t): return "c\(t)"
            case .table(let rows): return "t\(rows.flatMap { $0 }.joined())"
            case .rule: return "r\(UUID().uuidString)"
            case .questions(let t): return "Q\(t)"
            }
        }
    }

    var body: some View {
        let blocks = MarkdownView.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(MarkdownView.inline(t))
                .font(level <= 1 ? .title2.weight(.bold) : (level == 2 ? .title3.weight(.semibold) : .headline))
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            Text(MarkdownView.inline(t))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: indent == 0 ? "•" : (indent == 1 ? "◦" : "▪︎"))
                    .foregroundStyle(.secondary)
                Text(MarkdownView.inline(t))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18 + 4)
        case .numbered(let indent, let number, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: number + ".")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(MarkdownView.inline(t))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(MarkdownView.inline(t))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: t)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .environment(\.layoutDirection, .leftToRight)
        case .table(let rows):
            table(rows)
        case .rule:
            Divider().padding(.vertical, 4)
        case .questions(let title):
            Label {
                Text(MarkdownView.inline(title)).font(.headline)
            } icon: {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color.accentColor)
            }
            .padding(.top, 6)
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(MarkdownView.inline(c < row.count ? row[c] : ""))
                            .font(r == 0 ? .callout.weight(.semibold) : .callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(r == 0 ? Color.primary.opacity(0.07) : (r % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                    }
                }
                if r < rows.count - 1 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Inline (bold, italic, code, links)

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Parsing

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]? = nil
        var tableRows: [[String]] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushTable() {
            if !tableRows.isEmpty { blocks.append(.table(tableRows)) }
            tableRows = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code blocks
            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph(); flushTable()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }

            // Tables
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                flushParagraph()
                let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }
                if !isSeparator { tableRows.append(cells) }
                continue
            } else {
                flushTable()
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            let indent = (line.prefix { $0 == " " }.count) / 2

            // Separator
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let ch = trimmed.first, "-*_".contains(ch) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            // Headings
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let content = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !content.isEmpty {
                    flushParagraph()
                    blocks.append(isQuestionsTitle(content) ? .questions(title: content) : .heading(level: level, text: content))
                    continue
                }
            }

            // Bullets
            if let first = trimmed.first, "-*•+".contains(first), trimmed.dropFirst().first == " " {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: String(trimmed.dropFirst(2))))
                continue
            }

            // Numbered
            if let match = trimmed.range(of: #"^\d{1,3}[\.\)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let number = trimmed[match].filter(\.isNumber)
                blocks.append(.numbered(indent: indent, number: String(number), text: String(trimmed[match.upperBound...])))
                continue
            }

            // Quotes
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                continue
            }

            // A bold line on its own ("**מה טוב:**") reads as a small heading.
            if paragraph.isEmpty, trimmed.hasPrefix("**"), trimmed.hasSuffix("**") || trimmed.hasSuffix("**:") || trimmed.hasSuffix(":**"),
               trimmed.count < 80 {
                let content = trimmed.replacingOccurrences(of: "**", with: "")
                blocks.append(isQuestionsTitle(content) ? .questions(title: content) : .heading(level: 4, text: content))
                continue
            }
            if paragraph.isEmpty, isQuestionsTitle(trimmed), trimmed.count < 30 {
                blocks.append(.questions(title: trimmed))
                continue
            }

            paragraph.append(trimmed)
        }
        if let lines = codeLines { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }

    private static func isQuestionsTitle(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " :*"))
        return t == "שאלות" || t == "שאלות להמשך" || t == "שאלות אליך"
    }
}
