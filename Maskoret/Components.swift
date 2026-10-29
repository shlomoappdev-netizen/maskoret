import SwiftUI

// MARK: - Formatting

enum Fmt {
    static let locale = Locale(identifier: "he_IL")

    /// Whole shekels when there are no agorot (120 ₪), otherwise always two digits (12.50 ₪, 3,326.53 ₪).
    static func money(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        let digits = abs(rounded - rounded.rounded()) < 0.001 ? 0 : 2
        return rounded.formatted(.currency(code: "ILS").locale(locale).precision(.fractionLength(digits)))
    }

    /// Shows agorot when there are any (3,326.53 ₪), whole shekels otherwise (3,327 ₪).
    static func moneyRounded(_ value: Double) -> String {
        money(value)
    }

    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).locale(locale))
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
    }

    /// `value` is already a percentage (e.g. 6 → "6%").
    static func percent(_ value: Double) -> String {
        number(value) + "%"
    }

    /// Human-friendly duration from a number of months.
    static func duration(months: Double) -> String {
        if months < 1 {
            let days = Int((months * 30.4375).rounded())
            return days == 1 ? "יום אחד" : "\(days) ימים"
        }
        if months < 24 {
            let m = (months * 10).rounded() / 10
            return m == 1 ? "חודש אחד" : "\(number(m)) חודשים"
        }
        return "\(number((months / 12 * 10).rounded() / 10)) שנים"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    static let monthNames: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Fmt.locale
        return calendar.standaloneMonthSymbols
    }()

    static func monthTitle(year: Int, month: Int) -> String {
        let index = min(max(month, 1), 12) - 1
        return "\(monthNames[index]) \(year)"
    }
}

// MARK: - Colors

enum Palette {
    #if os(macOS)
    static let window = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    #else
    static let window = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
    static let fill = Color.primary.opacity(0.06)
}

// MARK: - RTL / Hebrew environment

extension View {
    func hebrew() -> some View {
        self
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Fmt.locale)
    }
}

// MARK: - Amount input

/// A numeric text field that updates a Double binding on every keystroke.
struct AmountField: View {
    let title: String
    @Binding var value: Double
    var suffix: String = "₪"

    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField("", text: $text, prompt: Text(verbatim: "0"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 130)
                .onChange(of: text) { _, newValue in
                    value = AmountField.parse(newValue)
                }
            Text(verbatim: suffix)
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .leading)
        }
        .onAppear { text = AmountField.display(value) }
    }

    static func parse(_ string: String) -> Double {
        let normalized = string.replacingOccurrences(of: ",", with: ".")
        let cleaned = normalized.filter { "0123456789.".contains($0) }
        return Double(cleaned) ?? 0
    }

    static func display(_ value: Double) -> String {
        guard value != 0 else { return "" }
        return value.formatted(
            .number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))
        )
    }
}

// MARK: - Sheet container (Mac-style dialog)

struct SheetContainer<Content: View>: View {
    let title: String
    let saveTitle: String
    let width: CGFloat
    let minHeight: CGFloat
    let onSave: (() -> Void)?
    let content: Content

    @Environment(\.dismiss) private var dismiss

    /// Pass `onSave: nil` for a read-only dialog with a single "סגור" button.
    init(
        title: String,
        saveTitle: String = "שמירה",
        width: CGFloat = 480,
        minHeight: CGFloat = 460,
        onSave: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.width = width
        self.minHeight = minHeight
        self.onSave = onSave
        self.content = content()
    }

    var body: some View {
        #if os(iOS)
        phoneBody
        #else
        macBody
        #endif
    }

    #if os(iOS)
    /// iPhone / iPad: a full-width form with the title and the buttons in the navigation bar, like any iOS sheet.
    private var phoneBody: some View {
        NavigationStack {
            Form {
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onSave {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("ביטול") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveTitle) {
                            onSave()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("סגור") { dismiss() }
                    }
                }
            }
        }
        .hebrew()
    }
    #endif

    private var macBody: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 4)

            Form {
                content
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                if let onSave {
                    Button("ביטול") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(saveTitle) {
                        onSave()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("סגור") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: width)
        .frame(minHeight: minHeight, idealHeight: max(minHeight, 620))
        .hebrew()
    }
}

// MARK: - Cards & rows

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

struct BreakdownLine: View {
    let title: String
    let value: Double
    var symbol: String = ""
    var color: Color = .primary
    var emphasized: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(emphasized ? .headline : .body)
            Spacer()
            Text(verbatim: symbol + Fmt.money((value * 100).rounded() / 100))
                .font(emphasized ? .headline : .body)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

struct SubLine: View {
    let title: String
    let value: Double

    var body: some View {
        HStack {
            Text(verbatim: "• " + title)
            Spacer()
            Text(verbatim: Fmt.money((value * 100).rounded() / 100)).monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
    }
}

/// Full gross → net → remaining breakdown, including each item.
struct BudgetBreakdown: View {
    let budget: Budget
    var showItems: Bool = true
    /// Only gross → deductions → net (the payslip part).
    var payslipOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BreakdownLine(title: "הכנסה ברוטו", value: budget.gross)
            if showItems {
                ForEach(budget.incomes.filter { $0.isActive && !$0.isNet }) { item in
                    SubLine(title: item.name, value: item.monthlyTotal)
                }
            }

            BreakdownLine(title: "ניכויים", value: budget.totalDeductions, symbol: "− ", color: .orange)
            if showItems {
                ForEach(budget.deductions.filter { $0.isActive }) { item in
                    SubLine(title: item.name, value: budget.deductionAmount(item))
                }
            }

            if budget.netIncomes > 0 {
                BreakdownLine(title: "הכנסות נטו (ללא ניכויים)", value: budget.netIncomes, symbol: "+ ", color: .green)
                if showItems {
                    ForEach(budget.incomes.filter { $0.isActive && $0.isNet }) { item in
                        SubLine(title: item.name, value: item.monthlyTotal)
                    }
                }
            }

            Divider()
            BreakdownLine(title: "נטו", value: budget.net, emphasized: true)
            if !payslipOnly {
            Divider()

            BreakdownLine(title: "הוצאות קבועות", value: budget.totalExpenses, symbol: "− ", color: .pink)
            if showItems {
                ForEach(budget.expenses.filter { $0.isActive }) { item in
                    SubLine(title: item.name, value: item.amount(base: budget.expenseBase))
                }
            }

            if budget.trackedItems.contains(where: { $0.includeInBudget }) {
                BreakdownLine(title: "רכישות תקופתיות", value: budget.periodicTotal, symbol: "− ", color: .purple)
                if showItems {
                    ForEach(budget.trackedItems.filter { $0.includeInBudget && $0.monthlyCost > 0 }) { item in
                        SubLine(title: item.emoji + " " + item.name, value: item.monthlyCost)
                    }
                }
            }

            Divider()
            BreakdownLine(
                title: "יתרה בסוף החודש",
                value: budget.remaining,
                color: budget.remaining >= 0 ? .green : .red,
                emphasized: true
            )
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

struct RateLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}

/// Page title with action buttons — Mac toolbars can hide actions in an overflow menu, so they live here.
struct PageBar<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title.weight(.bold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            // iPhone: the title is in the navigation bar; the subtitle, then the buttons in a row that scrolls sideways.
            VStack(alignment: .leading, spacing: 10) {
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { actions }
                        .controlSize(.small)
                        .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            wide
        }
        #else
        wide
        #endif
    }

    private var wide: some View {
        HStack(alignment: .center, spacing: 10) {
            titleBlock
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Row action buttons shown on hover-free Mac lists (edit / delete via context menu).
struct RowMenu: ViewModifier {
    let onEdit: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    onEdit()
                } label: {
                    Label("עריכה", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("מחיקה", systemImage: "trash")
                }
            }
    }
}

extension View {
    func rowMenu(onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        modifier(RowMenu(onEdit: onEdit, onDelete: onDelete))
    }
}

// MARK: - Narrow screens (iPhone)

extension EnvironmentValues {
    /// True on an iPhone (and iPad split view) — layouts made for the Mac window stack vertically there.
    var isCompactWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }
}

/// Side by side on the Mac / iPad, one under the other on an iPhone.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 16
    /// How the items line up when stacked on an iPhone.
    var compactAlignment: HorizontalAlignment = .leading
    var wideAlignment: VerticalAlignment = .top
    @ViewBuilder var content: Content
    @Environment(\.isCompactWidth) private var compact

    var body: some View {
        if compact {
            VStack(alignment: compactAlignment, spacing: spacing) { content }
        } else {
            HStack(alignment: wideAlignment, spacing: spacing) { content }
        }
    }
}

private struct RegularWidth: ViewModifier {
    let width: CGFloat
    let compactWidth: CGFloat?
    @Environment(\.isCompactWidth) private var compact

    func body(content: Content) -> some View {
        if !compact {
            content.frame(width: width)
        } else if let compactWidth {
            content.frame(width: compactWidth)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// A fixed width on wide screens; on an iPhone `compact` (or the full width when nil).
    func regularWidth(_ width: CGFloat, compact: CGFloat? = nil) -> some View {
        modifier(RegularWidth(width: width, compactWidth: compact))
    }
}

// MARK: - Labeled text field

/// A text field with its title. On the Mac a Form shows the title next to the field by itself;
/// on iOS it would only be a placeholder, so the title is shown on the side and the field fills the rest.
struct FormTextField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var prompt: Text?

    init(_ title: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        #if os(iOS)
        LabeledContent(title) {
            TextField(title, text: $text, prompt: prompt)
                .multilineTextAlignment(.trailing)
        }
        #else
        TextField(title, text: $text, prompt: prompt)
        #endif
    }
}
