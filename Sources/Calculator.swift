// Sums typed into the bar ("12*4.5", "(3+4)/2", "15% of 80"), like Spotlight. A small parser
// of its own, so nothing a person types can crash the app.

import Foundation

enum Calculator {
    /// The result, or nil when the text isn't a sum.
    static func evaluate(_ text: String) -> Double? {
        var s = text.lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "=", with: "")
        // "15% of 80", on its own or inside a longer sum
        s = s.replacingOccurrences(of: #"([0-9.]+)%of([0-9.]+)"#, with: "($1/100*$2)", options: .regularExpression)
        s = s.replacingOccurrences(of: "%", with: "/100")
        // Must look like a sum: digits and at least one operator, nothing else.
        guard s.range(of: #"^[0-9.+\-*/^()]+$"#, options: .regularExpression) != nil,
              s.range(of: #"[+\-*/^]"#, options: .regularExpression) != nil,
              s.range(of: #"[0-9]"#, options: .regularExpression) != nil else { return nil }
        var p = Parser(Array(s))
        guard let value = p.expression(), p.done, value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// expression := term (('+'|'-') term)* ; term := power (('*'|'/') power)* ;
    /// power := unary ('^' power)? ; unary := '-' unary | primary ; primary := number | '(' expression ')'
    private struct Parser {
        let chars: [Character]
        var i = 0
        var depth = 0
        init(_ chars: [Character]) { self.chars = chars }
        var done: Bool { i == chars.count }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while i < chars.count, chars[i] == "*" || chars[i] == "/" {
                let op = chars[i]; i += 1
                guard let rhs = power() else { return nil }
                if op == "/" && rhs == 0 { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < chars.count, chars[i] == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }
        mutating func unary() -> Double? {
            if i < chars.count, chars[i] == "-" { i += 1; return unary().map { -$0 } }
            return primary()
        }
        mutating func primary() -> Double? {
            guard i < chars.count else { return nil }
            if chars[i] == "(" {
                depth += 1
                guard depth < 50 else { return nil }
                i += 1
                let value = expression()
                guard i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                depth -= 1
                return value
            }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}
