//
//  JsonSerializer.swift
//  JsonSerializer
//
//  Created by Fuji Goro on 2014/09/11.
//  Copyright (c) 2014 Fuji Goro. All rights reserved.
//  License: The MIT License
//

import Darwin

// C-like conversion from Byte to CChar
func byte2cchar(b: Byte) -> CChar {
    if b < 0x80 {
        return CChar(b)
    } else {
        return -0x80 + CChar(b & ~Byte(0x80))
    }
}

public class JsonParser: Parser {

    public class func parse(source: StaticString) -> Result {
        let begin = source.start
        let end = begin.advancedBy(Int(source.byteSize))
        return JsonParser(source.stringValue, begin, end).parse()
    }

    public class func parse(begin: UnsafePointer<Byte>, end: UnsafePointer<Byte>) -> Result {
        return JsonParser(nil, begin, end).parse()
    }

    typealias Iterator = UnsafePointer<Byte>


    let originalSource: AnyObject?
    let beg: Iterator
    let end: Iterator
    var cur: Iterator

    public var lineNumber = 1
    public var columnNumber = 1

    public init(_ source: AnyObject?, _ begin: UnsafePointer<Byte>, _ end: UnsafePointer<Byte>) {
        self.originalSource = source
        self.beg = begin
        self.end = end
        self.cur = begin
    }

    public enum Result {
        case Success(Json)
        case Error(ParseError)
    }


    func parse() -> Result {
        switch parseValue() {
        case .Success(let json):
            skipWhitespaces()
            if (cur == end) {
                return .Success(json)
            } else {
                return .Error(ExtraTokenError("extra tokens found", self))
            }
        case .Error(let error):
            return .Error(error)
        }
    }

    func parseValue() -> Result {
        skipWhitespaces()

        if cur == end {
            return .Error(InsufficientTokenError("unexpected end of tokens", self))
        }

        switch cur.memory {
        case Byte("n"):
            return parseSymbol("null", Json.NullValue)
        case Byte("t"):
            return parseSymbol("true", Json.BooleanValue(true))
        case Byte("f"):
            return parseSymbol("false", Json.BooleanValue(false))
        case Byte("-"), Byte("0") ... Byte("9"):
            return parseNumber()
        case Byte("\""):
            return parseString()
        case Byte("{"):
            return parseObject()
        case Byte("["):
            return parseArray()
        case (let c):
            return .Error(UnexpectedTokenError("unexpected token: \(c)", self))
        }
    }

    var currentSymbol: Character {
        get { return Character(UnicodeScalar(cur.memory)) }
    }

    func parseSymbol(target: StaticString, _ iftrue: @autoclosure () -> Json) -> Result {
        if expect(target) {
            return .Success(iftrue())
        } else {
            return .Error(UnexpectedTokenError("expected \"\(target)\" but \(currentSymbol)", self))
        }
    }

    func parseString() -> Result {
        assert(cur.memory == Byte("\""), "points a double quote")
        nextChar()

        var buffer = [CChar]()

        LOOP: for ; cur != end; nextChar() {
            switch cur.memory {
            case Byte("\\"):
                nextChar()
                if (cur == end) {
                    return .Error(InsufficientTokenError("unexpected end of a string literal", self))
                }

                if let c = parseEscapedChar() {
                    for u in String(c).utf8 {
                        buffer.append(byte2cchar(u))
                    }
                } else {
                    return .Error(InvalidEscapeSequence("invalid escape sequence", self))
                }
                break
            case Byte("\""): // end of the string literal
                nextChar()
                break LOOP
            default:
                buffer.append(byte2cchar(cur.memory))
            }
        }
        buffer.append(0) // trailing nul

        let s = String.fromCString(buffer)!
        return .Success(.StringValue(s))
    }

    func parseEscapedChar() -> UnicodeScalar? {
        let c = UnicodeScalar(cur.memory)
        if c == "u" { // Unicode escape sequence
            var length = 0 // 2...8
            var value: UInt32 = 0
            while let d = hex2d((cur+1).memory) {
                nextChar()
                length++

                if length > 8 {
                    break
                }

                value = (value << 4) | d
            }
            if length < 2 {
                return nil
            }
            return UnicodeScalar(value)
        } else {
            let c = UnicodeScalar(cur.memory)
            return unescapeMapping[c] ?? c
        }
    }

    func hex2d(b: Byte) -> UInt32? {
        switch b {
        case Byte("0"): return 0x0
        case Byte("1"): return 0x1
        case Byte("2"): return 0x2
        case Byte("3"): return 0x3
        case Byte("4"): return 0x4
        case Byte("5"): return 0x5
        case Byte("6"): return 0x6
        case Byte("7"): return 0x7
        case Byte("8"): return 0x8
        case Byte("9"): return 0x9
        case Byte("a"), Byte("A"): return 0xA
        case Byte("b"), Byte("B"): return 0xB
        case Byte("c"), Byte("C"): return 0xC
        case Byte("d"), Byte("D"): return 0xD
        case Byte("e"), Byte("E"): return 0xE
        case Byte("f"), Byte("F"): return 0xF
        default:
            return nil
        }
    }

    func parseNumber() -> Result {
        let sign = expect("-") ? -1.0 : 1.0

        let start = index
        var n = Double()

        // integer
        LOOP: for ; cur != end; nextChar() {
            switch cur.memory {
            case Byte("0") ... Byte("9"):
                let d = String(UnicodeScalar(cur.memory)).toInt()!
                n = (n * 10.0) + Double(d)
            default:
                break LOOP
            }
        }

        // fraction
        if expect(".") {
            var factor = 0.1

            LOOP: for ; cur != end; nextChar() {
                switch cur.memory {
                case Byte("0") ... Byte("9"):
                    let d = String(UnicodeScalar(cur.memory)).toInt()!
                    n += (Double(d) * factor)
                    factor /= 10
                default:
                    break LOOP
                }
            }
        }

        return .Success(.NumberValue(sign * n))
    }

    func parseObject() -> Result {
        assert(cur.memory == Byte("{"), "points \"{\"")
        nextChar()

        var o = [String:Json]()

        LOOP: for ;cur != end && !expect("}"); nextChar() {
            // key
            switch parseValue() {
            case .Success(let keyValue):
                switch keyValue {
                case .StringValue(let key):
                    if !expect(":") {
                        return .Error(UnexpectedTokenError("missing colon (:)", self))
                    }

                    // value
                    switch parseValue() {
                    case .Success(let value):
                        o[key] = value
                        break
                    case (let error):
                        return error
                    }

                    skipWhitespaces()
                    if expect(",") {
                        break
                    } else if expect("}") {
                        break LOOP
                    } else {
                        return .Error(UnexpectedTokenError("missing comma (,)", self))
                    }
                default:
                    return .Error(NonStringKeyError("unexpected value for object key", self))
                }
            case (let error):
                return error
            }
        }

        return .Success(.ObjectValue(o))
    }

    func parseArray() -> Result {
        assert(cur.memory == Byte("["), "points \"[\"")
        nextChar()

        var a = Array<Json>()

        LOOP: for ;cur != end && !expect("]"); nextChar() {
            switch parseValue() {
            case .Success(let json):
                a.append(json)

                if expect(",") {
                    break
                } else if expect("]") {
                    break LOOP
                } else {
                    return .Error(UnexpectedTokenError("missing comma (,) (token: \(currentSymbol))", self))
                }
            case (let error):
                return error
            }

        }

        return .Success(.ArrayValue(a))
    }


    func expect(target: StaticString) -> Bool {
        skipWhitespaces()

        if !isIdentifier(target.start.memory) {
            // when single character
            if target.start.memory == cur.memory {
                nextChar()
                return true
            } else {
                return false
            }
        }

        let start = cur
        let l = lineNumber
        let c = columnNumber

        var p = target.start
        let endp = p.advancedBy(Int(target.byteSize))

        LOOP: for ; p != endp; p++, nextChar() {
            if !isIdentifier(cur.memory) {
                break
            }

            if p.memory != cur.memory {
                cur = start // unread
                lineNumber = l
                columnNumber = c
                return false
            }
        }

        return true
    }

    // only "true", "false", "null" are identifiers
    func isIdentifier(c: Byte) -> Bool {
        switch c {
        case Byte("a") ... Byte("z"):
            return true
        default:
            return false
        }
    }

    func nextChar() {
        cur++

        switch cur.memory {
        case Byte("\n"):
            lineNumber++
            columnNumber = 1
        default:
            columnNumber++
        }
    }

    func skipWhitespaces() {
        LOOP: for ; cur != end; nextChar() {
            switch cur.memory {
            case Byte(" "), Byte("\t"), Byte("\r"), Byte("\n"):
                break
            default:
                return
            }
        }
    }
}
