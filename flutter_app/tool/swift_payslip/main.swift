import Foundation

// Reads payslip texts (JSON array of strings) from stdin and prints PayslipReader.parse of each as JSON.
let input = FileHandle.standardInput.readDataToEndOfFile()
let texts = try! JSONSerialization.jsonObject(with: input) as! [String]
func value<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
let out: [[String: Any]] = texts.map { text in
    let r = PayslipReader.parse(text)
    return ["year": value(r.year), "month": value(r.month), "gross": value(r.gross), "deductions": value(r.deductions),
            "net": value(r.net), "netToPay": value(r.netToPay), "incomeTax": value(r.incomeTax),
            "nationalInsurance": value(r.nationalInsurance), "health": value(r.health), "verified": r.verified]
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
