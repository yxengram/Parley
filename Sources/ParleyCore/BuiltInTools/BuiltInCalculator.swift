import Foundation

/// `calculate`. A hand-written parser, because NSExpression's format strings can call methods and
/// crash. Everything is bounded by the length and depth caps, so it needs no timeout.
enum BuiltInCalculator {
    static let maxLength = 1000
    static let maxDepth = 64

    enum Failure: Error, Equatable {
        case empty, tooLong, tooDeep, divisionByZero, notFinite
        case unexpected(position: Int)
        case unknownName(String)

        var message: String {
            switch self {
            case .empty: return "The expression is empty."
            case .tooLong: return "The expression is longer than \(maxLength) characters."
            case .tooDeep: return "The expression is nested more than \(maxDepth) levels deep."
            case .divisionByZero: return "Division by zero."
            case .notFinite: return "The result is not a finite number."
            case .unexpected(let position): return "The expression could not be read at character \(position + 1)."
            case .unknownName(let name): return "Unknown name: \(name.prefix(40))."
            }
        }
    }

    static func evaluate(_ expression: String) throws -> Double {
        guard expression.unicodeScalars.count <= maxLength else { throw Failure.tooLong }
        var parser = Parser(text: Array(expression.unicodeScalars))
        parser.skipSpaces()
        guard !parser.atEnd else { throw Failure.empty }
        let value = try parser.sum(depth: 0)
        parser.skipSpaces()
        guard parser.atEnd else { throw Failure.unexpected(position: parser.position) }
        guard value.isFinite else { throw Failure.notFinite }
        return value
    }

    /// Whole numbers under 1e15 with no decimal point, the rest in 15 significant digits. `%g` with
    /// no locale, so a decimal comma never reaches the model.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.15g", value)
    }

    private struct Parser {
        let text: [Unicode.Scalar]
        var position = 0

        var atEnd: Bool { position >= text.count }
        private var current: Unicode.Scalar? { atEnd ? nil : text[position] }

        mutating func skipSpaces() {
            while let scalar = current, scalar.properties.isWhitespace { position += 1 }
        }

        /// The operator at the cursor, if it is one of `operators`.
        private mutating func take(_ operators: String) -> Unicode.Scalar? {
            skipSpaces()
            guard let scalar = current, operators.unicodeScalars.contains(scalar) else { return nil }
            position += 1
            return scalar
        }

        mutating func sum(depth: Int) throws -> Double {
            var value = try product(depth: depth)
            while let op = take("+-") {
                let right = try product(depth: depth)
                value = op == "+" ? value + right : value - right
            }
            return value
        }

        private mutating func product(depth: Int) throws -> Double {
            var value = try unary(depth: depth)
            while let op = take("*/%") {
                let right = try unary(depth: depth)
                if op == "*" {
                    value *= right
                } else {
                    guard right != 0 else { throw Failure.divisionByZero }
                    value = op == "/" ? value / right : fmod(value, right)
                }
            }
            return value
        }

        /// Below `^` on the left, so -2^2 is -4, and on its right, so 2^-1 works.
        private mutating func unary(depth: Int) throws -> Double {
            guard depth < maxDepth else { throw Failure.tooDeep }
            if let op = take("+-") {
                let value = try unary(depth: depth + 1)
                return op == "-" ? -value : value
            }
            let base = try primary(depth: depth)
            guard take("^") != nil else { return base }
            return pow(base, try unary(depth: depth + 1))
        }

        private mutating func primary(depth: Int) throws -> Double {
            skipSpaces()
            guard let scalar = current else { throw Failure.unexpected(position: position) }
            if scalar == "(" {
                position += 1
                let value = try sum(depth: depth + 1)
                try close()
                return value
            }
            if Self.isDigit(scalar) || scalar == "." { return try number() }
            guard Self.isLetter(scalar) else { throw Failure.unexpected(position: position) }
            return try named(depth: depth)
        }

        private mutating func close() throws {
            guard take(")") != nil else { throw Failure.unexpected(position: position) }
        }

        private mutating func number() throws -> Double {
            let start = position
            func digits(_ index: inout Int) { while index < text.count, Self.isDigit(text[index]) { index += 1 } }
            digits(&position)
            if current == "." {
                position += 1
                digits(&position)
            }
            // "2e" is 2 and then a stray name, and "2e3" is a number: the exponent needs its digits.
            if current == "e" || current == "E" {
                var next = position + 1
                if next < text.count, text[next] == "+" || text[next] == "-" { next += 1 }
                let digitsStart = next
                digits(&next)
                if next > digitsStart { position = next }
            }
            var token = String.UnicodeScalarView()
            token.append(contentsOf: text[start..<position])
            guard let value = Double(String(token)) else { throw Failure.unexpected(position: start) }
            return value
        }

        private mutating func named(depth: Int) throws -> Double {
            var token = String.UnicodeScalarView()
            while let scalar = current, Self.isLetter(scalar) || Self.isDigit(scalar) {
                token.append(scalar)
                position += 1
            }
            let name = String(token).lowercased()
            if name == "pi" { return .pi }
            if name == "e" { return M_E }
            guard let function = Self.functions[name] else { throw Failure.unknownName(name) }
            guard take("(") != nil else { throw Failure.unexpected(position: position) }
            let argument = try sum(depth: depth + 1)
            try close()
            return function(argument)
        }

        private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
        private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }

        private static let functions: [String: (Double) -> Double] = [
            "sqrt": sqrt, "abs": { Swift.abs($0) }, "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos,
            "atan": atan, "log": log10, "ln": log, "exp": exp, "floor": floor, "ceil": ceil, "round": { $0.rounded() },
        ]
    }
}
