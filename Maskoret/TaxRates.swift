import Foundation

/// One monthly income-tax bracket. `upTo == nil` means "and above".
struct TaxBracket: Codable, Equatable, Hashable {
    var upTo: Double?
    var rate: Double // percent
}

struct RateSource: Codable, Equatable, Hashable {
    var title: String
    var url: String
}

/// Official Israeli payroll-deduction parameters (monthly values, employees).
/// A copy ships inside the app and newer versions are downloaded from `Store.ratesURL`.
struct TaxRates: Codable, Equatable {
    var version: Int
    var year: Int
    var updated: String

    // Income tax (רשות המסים)
    var brackets: [TaxBracket]
    var surtaxMonthlyThreshold: Double
    var surtaxRate: Double
    var creditPointValue: Double

    // National insurance & health (ביטוח לאומי)
    var niReducedThreshold: Double
    var niMaxIncome: Double
    var niReducedRate: Double
    var niFullRate: Double
    var healthReducedRate: Double
    var healthFullRate: Double

    // Pension credit (סעיף 45א)
    var pensionCreditRate: Double
    var pensionCreditMaxPercent: Double
    var pensionInsuredSalaryCap: Double

    var sources: [RateSource]

    /// Values for 2026, taken from gov.il (Tax Authority) and btl.gov.il.
    static let bundled = TaxRates(
        version: 2026_04_01,
        year: 2026,
        updated: "2026-04-01",
        brackets: [
            TaxBracket(upTo: 7_010, rate: 10),
            TaxBracket(upTo: 10_060, rate: 14),
            TaxBracket(upTo: 19_000, rate: 20),
            TaxBracket(upTo: 25_100, rate: 31),
            TaxBracket(upTo: 46_690, rate: 35),
            TaxBracket(upTo: nil, rate: 47)
        ],
        surtaxMonthlyThreshold: 60_130,
        surtaxRate: 3,
        creditPointValue: 242,
        niReducedThreshold: 7_703,
        niMaxIncome: 51_910,
        niReducedRate: 1.04,
        niFullRate: 7,
        healthReducedRate: 3.23,
        healthFullRate: 5.17,
        pensionCreditRate: 35,
        pensionCreditMaxPercent: 7,
        pensionInsuredSalaryCap: 9_700,
        sources: [
            RateSource(
                title: "רשות המסים — מדרגות מס 2026 (ריווח מדרגות, רטרואקטיבי מ-1.1.2026)",
                url: "https://www.gov.il/BlobFolder/dynamiccollectorresultitem/employers-info-300326-1/he/IncomeTax_IncomeTaxEmployersInfo_employers-info-300326-1.pdf"
            ),
            RateSource(
                title: "רשות המסים — לוח עזר לחישוב מס ממשכורת 2026 (נקודת זיכוי, מס יסף)",
                url: "https://www.gov.il/BlobFolder/generalpage/income-tax-monthly-deductions-booklet/he/generalInformation_income-tax-monthly-deductions-booklet_monthly-deductions-booklet-2026.pdf"
            ),
            RateSource(
                title: "ביטוח לאומי — שיעורי דמי ביטוח לעובדים שכירים",
                url: "https://www.btl.gov.il/Insurance/Rates/Pages/%D7%9C%D7%A2%D7%95%D7%91%D7%93%D7%99%D7%9D%20%D7%A9%D7%9B%D7%99%D7%A8%D7%99%D7%9D.aspx"
            )
        ]
    )
}

/// Pure calculation helpers — all amounts are monthly.
enum TaxCalc {
    static func bracketTax(_ income: Double, rates: TaxRates) -> Double {
        guard income > 0 else { return 0 }
        var tax = 0.0
        var lower = 0.0
        for bracket in rates.brackets {
            let upper = bracket.upTo ?? Double.greatestFiniteMagnitude
            if income > lower {
                tax += (min(income, upper) - lower) * bracket.rate / 100
            }
            if income <= upper { break }
            lower = upper
        }
        tax += max(0, income - rates.surtaxMonthlyThreshold) * rates.surtaxRate / 100
        return tax
    }

    static func pensionCredit(contribution: Double, gross: Double, rates: TaxRates) -> Double {
        let maxEligible = min(gross, rates.pensionInsuredSalaryCap) * rates.pensionCreditMaxPercent / 100
        return min(contribution, maxEligible) * rates.pensionCreditRate / 100
    }

    static func incomeTax(gross: Double, creditPoints: Double, pensionContribution: Double, rates: TaxRates) -> Double {
        let before = bracketTax(gross, rates: rates)
        let credits = creditPoints * rates.creditPointValue
            + pensionCredit(contribution: pensionContribution, gross: gross, rates: rates)
        return max(0, before - credits)
    }

    private static func twoTier(_ gross: Double, reduced: Double, full: Double, rates: TaxRates) -> Double {
        let reducedPart = min(max(gross, 0), rates.niReducedThreshold)
        let fullPart = max(0, min(gross, rates.niMaxIncome) - rates.niReducedThreshold)
        return reducedPart * reduced / 100 + fullPart * full / 100
    }

    static func nationalInsurance(gross: Double, rates: TaxRates) -> Double {
        twoTier(gross, reduced: rates.niReducedRate, full: rates.niFullRate, rates: rates)
    }

    static func healthInsurance(gross: Double, rates: TaxRates) -> Double {
        twoTier(gross, reduced: rates.healthReducedRate, full: rates.healthFullRate, rates: rates)
    }
}
