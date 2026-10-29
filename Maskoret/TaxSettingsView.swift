import SwiftUI

/// Full page (sidebar → נתוני מס).
struct TaxSettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                TaxSettingsSections()
            }
            .formStyle(.grouped)
            .navigationTitle("נתוני מס")
        }
    }
}

/// The settings content — used both as a page and inside a dialog.
struct TaxSettingsSections: View {
    @EnvironmentObject private var store: Store

    private var rates: TaxRates { store.budget.rates }

    var body: some View {
        creditPointsSection
        pensionSection
        incomeTaxSection
        insuranceSection
        updateSection
        sourcesSection
    }

    // MARK: Credit points

    private var creditPointsSection: some View {
        Section {
            Stepper(value: $store.budget.taxSettings.creditPoints, in: 0...20, step: 0.25) {
                HStack {
                    Text("נקודות זיכוי")
                    Spacer()
                    Text(verbatim: Fmt.number(store.budget.taxSettings.creditPoints))
                        .monospacedDigit()
                        .bold()
                }
            }
            RateLine(title: "שווי בחודש", value: Fmt.money(store.budget.taxSettings.creditPoints * rates.creditPointValue))
        } header: {
            Text("נקודות זיכוי")
        } footer: {
            Text("תושב/ת ישראל: 2.25 · אישה: עוד 0.5 · חייל/ת משוחרר/ת: עד 2 נקודות למשך 3 שנים מהשחרור (לפי משך השירות) · סיום תואר ראשון: נקודה אחת לשנה · ילדים: לפי גילם. המספר המדויק מופיע בתלוש השכר.")
        }
    }

    // MARK: Pension

    private var pensionSection: some View {
        Section {
            Picker("פנסיה מהתלוש", selection: $store.budget.taxSettings.pensionMode) {
                ForEach(PensionMode.allCases) { Text($0.title).tag($0) }
            }
            if store.budget.taxSettings.pensionMode == .startsLater {
                DatePicker("מתחיל להפריש ב-", selection: Binding(
                    get: { store.budget.taxSettings.pensionStart ?? Date() },
                    set: { store.budget.taxSettings.pensionStart = $0 }
                ), displayedComponents: .date)
            }
            let active = store.budget.taxSettings.contributesPension()
            let hasItem = store.budget.deductions.contains { $0.auto == .pension }
            RateLine(title: "כרגע", value: active
                     ? (hasItem ? "יורדת פנסיה — " + Fmt.money(store.budget.pensionContribution) : "מפריש, אבל אין שורת ״פנסיה״ בניכויים")
                     : "לא יורדת פנסיה, ואין זיכוי מס על הפרשה")
        } header: {
            Text("פנסיה")
        } footer: {
            Text("בדרך כלל חובת ההפרשה מתחילה מגיל 21 לגבר ו-20 לאישה, ואחרי חצי שנה במקום העבודה (או 3 חודשים למי שכבר היה לו קרן פנסיה) — אבל כדאי לבדוק בתלוש או מול המעסיק. ״יתחיל מתאריך״ מפעיל את הניכוי לבד כשמגיע התאריך. אחוז ההפרשה עצמו נקבע בשורת ״פנסיה״ בעמוד ניכויים.")
        }
    }

    // MARK: Rates display

    private var incomeTaxSection: some View {
        Section {
            ForEach(Array(rates.brackets.enumerated()), id: \.offset) { index, bracket in
                RateLine(title: bracketRange(index), value: Fmt.percent(bracket.rate))
            }
            RateLine(title: "מס יסף", value: Fmt.percent(rates.surtaxRate) + " מעל " + Fmt.moneyRounded(rates.surtaxMonthlyThreshold))
            RateLine(title: "שווי נקודת זיכוי", value: Fmt.money(rates.creditPointValue))
            RateLine(
                title: "זיכוי פנסיה",
                value: Fmt.percent(rates.pensionCreditRate) + " על עד " + Fmt.percent(rates.pensionCreditMaxPercent)
                    + " משכר של עד " + Fmt.moneyRounded(rates.pensionInsuredSalaryCap)
            )
        } header: {
            Text(verbatim: "מס הכנסה — מדרגות חודשיות \(rates.year)")
        }
    }

    private func bracketRange(_ index: Int) -> String {
        let lower = index == 0 ? 0 : (rates.brackets[index - 1].upTo ?? 0)
        if let upper = rates.brackets[index].upTo {
            return index == 0
                ? "עד " + Fmt.moneyRounded(upper)
                : Fmt.moneyRounded(lower + 1) + " – " + Fmt.moneyRounded(upper)
        }
        return "מעל " + Fmt.moneyRounded(lower)
    }

    private var insuranceSection: some View {
        Section {
            RateLine(title: "סף שיעור מופחת", value: Fmt.moneyRounded(rates.niReducedThreshold))
            RateLine(title: "הכנסה מרבית", value: Fmt.moneyRounded(rates.niMaxIncome))
            RateLine(title: "ביטוח לאומי", value: Fmt.percent(rates.niReducedRate) + " / " + Fmt.percent(rates.niFullRate))
            RateLine(title: "מס בריאות", value: Fmt.percent(rates.healthReducedRate) + " / " + Fmt.percent(rates.healthFullRate))
        } header: {
            Text("ביטוח לאומי ומס בריאות (עובד)")
        } footer: {
            Text("שיעור מופחת / שיעור מלא.")
        }
    }

    // MARK: Update

    private var updateSection: some View {
        Section {
            RateLine(title: "גרסת נתונים", value: rates.updated)
            if let last = store.lastRatesCheck {
                RateLine(title: "בדיקה אחרונה", value: last.formatted(.dateTime.day().month().hour().minute().locale(Fmt.locale)))
            }
            HStack {
                Button {
                    Task { await store.refreshRates(force: true) }
                } label: {
                    Label("בדוק עדכונים עכשיו", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.isCheckingRates)
                if store.isCheckingRates {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if !store.ratesStatus.isEmpty {
                Text(store.ratesStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FormTextField("כתובת קובץ העדכון", text: $store.ratesURL)
                .font(.callout.monospaced())
                .environment(\.layoutDirection, .leftToRight)
        } header: {
            Text("עדכון אוטומטי")
        } footer: {
            Text("האפליקציה בודקת פעמיים ביום אם פורסמו שיעורים חדשים ומעדכנת לבד. החישוב הוא הערכה לשכיר — הוא לא כולל שווי הטבות, הפרשות מעסיק מעל התקרה או תיאום מס, ולכן עשוי להיות שונה במעט מהתלוש.")
        }
    }

    private var sourcesSection: some View {
        Section("מקורות רשמיים") {
            ForEach(rates.sources, id: \.url) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        Label(source.title, systemImage: "link")
                    }
                }
            }
        }
    }
}
