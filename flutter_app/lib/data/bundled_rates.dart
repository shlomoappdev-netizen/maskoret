// Generated from rates/tax-rates.json (the same values as TaxRates.bundled in the Swift app).
// A nil `upTo` is left out, like Swift's encoder does.
const Map<String, dynamic> bundledRatesJson = {
  "version": 20260401,
  "year": 2026,
  "updated": "2026-04-01",
  "brackets": [
    {
      "upTo": 7010,
      "rate": 10
    },
    {
      "upTo": 10060,
      "rate": 14
    },
    {
      "upTo": 19000,
      "rate": 20
    },
    {
      "upTo": 25100,
      "rate": 31
    },
    {
      "upTo": 46690,
      "rate": 35
    },
    {
      "rate": 47
    }
  ],
  "surtaxMonthlyThreshold": 60130,
  "surtaxRate": 3,
  "creditPointValue": 242,
  "niReducedThreshold": 7703,
  "niMaxIncome": 51910,
  "niReducedRate": 1.04,
  "niFullRate": 7,
  "healthReducedRate": 3.23,
  "healthFullRate": 5.17,
  "pensionCreditRate": 35,
  "pensionCreditMaxPercent": 7,
  "pensionInsuredSalaryCap": 9700,
  "sources": [
    {
      "title": "רשות המסים — מדרגות מס 2026 (ריווח מדרגות, רטרואקטיבי מ-1.1.2026)",
      "url": "https://www.gov.il/BlobFolder/dynamiccollectorresultitem/employers-info-300326-1/he/IncomeTax_IncomeTaxEmployersInfo_employers-info-300326-1.pdf"
    },
    {
      "title": "רשות המסים — לוח עזר לחישוב מס ממשכורת 2026 (נקודת זיכוי, מס יסף)",
      "url": "https://www.gov.il/BlobFolder/generalpage/income-tax-monthly-deductions-booklet/he/generalInformation_income-tax-monthly-deductions-booklet_monthly-deductions-booklet-2026.pdf"
    },
    {
      "title": "ביטוח לאומי — שיעורי דמי ביטוח לעובדים שכירים",
      "url": "https://www.btl.gov.il/Insurance/Rates/Pages/%D7%9C%D7%A2%D7%95%D7%91%D7%93%D7%99%D7%9D%20%D7%A9%D7%9B%D7%99%D7%A8%D7%99%D7%9D.aspx"
    }
  ]
};
