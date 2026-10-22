import Foundation

/// Minimal port of Python `html.unescape` (CTO ruling Q3): named amp/lt/gt/quot/apos/nbsp
/// (with `;`, and the HTML legacy no-semicolon forms of amp/lt/gt/quot/nbsp, longest prefix,
/// as Python does) plus every numeric `&#NN;` / `&#xHH;` (semicolon optional).
/// Anything else is left untouched, exactly as Python leaves unknown entities.
public enum HTML {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]
    private static let legacy = ["nbsp", "quot", "amp", "lt", "gt"]  // valid without ';'
    // Same shape as CPython's html._charref.
    private static let rx = try! NSRegularExpression(
        pattern: "&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\\t\\n\\f <&#;]{1,32};?)")

    public static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += replace(ns.substring(with: m.range(at: 1)))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func replace(_ body: String) -> String {
        if body.hasPrefix("#") {
            var digits = body.dropFirst()
            if digits.hasSuffix(";") { digits = digits.dropLast() }
            let num: UInt32?
            if digits.first == "x" || digits.first == "X" {
                num = UInt32(digits.dropFirst(), radix: 16)
            } else {
                num = UInt32(digits, radix: 10)
            }
            guard let n = num, n != 0, !(0xD800...0xDFFF).contains(n), n <= 0x10FFFF,
                  let sc = Unicode.Scalar(n) else { return "\u{FFFD}" }
            return String(Character(sc))
        }
        if body.hasSuffix(";"), let v = named[String(body.dropLast())] { return v }
        // Legacy forms without ';': longest matching prefix, rest kept verbatim.
        for name in legacy.sorted(by: { $0.count > $1.count }) where body.hasPrefix(name) {
            return named[name]! + body.dropFirst(name.count)
        }
        return "&" + body
    }
}
