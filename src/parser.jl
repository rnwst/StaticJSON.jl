"""
    JSONValue(value)

A concrete wrapper for an untyped JSON value. Its payload is one of `nothing`,
`Bool`, `Float64`, `String`, `Vector{JSONValue}`, or
`Dict{String,JSONValue}`. The wrapper closes the recursive type without using
`Any`.
"""
struct JSONValue
    value::Union{
        Nothing,
        Bool,
        Float64,
        String,
        Dict{String,JSONValue},
        Vector{JSONValue},
    }
end

"""
    unwrap(value::JSONValue)

Return the payload stored in `value`. This operation removes exactly one
`JSONValue` layer; values inside arrays and objects remain wrapped.
"""
unwrap(value::JSONValue) = value.value

"""
    ParseError(message, position)

Exception raised for malformed JSON or a mismatch between JSON and a requested
target type. `position` is a one-based byte offset into the input string.
"""
struct ParseError <: Exception
    message::String
    position::Int
end

"""
    Base.showerror(io, error::ParseError)

Render a JSON parsing error with its one-based byte position.
"""
function Base.showerror(io::IO, error::ParseError)
    print(io, "StaticJSON.ParseError at byte ", error.position, ": ", error.message)
end

"""
    Cursor(source)

Mutable byte cursor used by the recursive-descent parser. JSON punctuation is
ASCII, so byte offsets avoid Julia's variable-width string indexing rules.
"""
mutable struct Cursor
    source::String
    position::Int
    limit::Int
end

"""
    Cursor(source::String)

Create a cursor positioned at the first byte of `source`.
"""
Cursor(source::String) = Cursor(source, 1, ncodeunits(source))

"""
    _fail(cursor, message)

Throw a `ParseError` at the cursor's current byte position.
"""
function _fail(cursor::Cursor, message::String)
    throw(ParseError(message, cursor.position))
end

"""
    _at_end(cursor)

Return whether every source byte has been consumed.
"""
_at_end(cursor::Cursor) = cursor.position > cursor.limit

"""
    _peek_byte(cursor)

Return the current byte, or zero when the cursor is at end of input.
"""
function _peek_byte(cursor::Cursor)
    _at_end(cursor) && return UInt8(0)
    return codeunit(cursor.source, cursor.position)
end

"""
    _take_byte!(cursor)

Consume and return the current byte, throwing on unexpected end of input.
"""
function _take_byte!(cursor::Cursor)
    _at_end(cursor) && _fail(cursor, "unexpected end of input")
    byte = codeunit(cursor.source, cursor.position)
    cursor.position += 1
    return byte
end

"""
    _expect_byte!(cursor, expected, message)

Consume `expected`, or throw with `message` if another byte is present.
"""
function _expect_byte!(cursor::Cursor, expected::UInt8, message::String)
    _peek_byte(cursor) == expected || _fail(cursor, message)
    cursor.position += 1
    return nothing
end

"""
    _skip_whitespace!(cursor)

Consume the four whitespace bytes admitted by RFC 8259.
"""
function _skip_whitespace!(cursor::Cursor)
    while !_at_end(cursor)
        byte = _peek_byte(cursor)
        (byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d) || break
        cursor.position += 1
    end
    return nothing
end

"""
    _consume_literal!(cursor, literal)

Consume an ASCII JSON literal such as `"true"`, rejecting truncated or
misspelled input.
"""
function _consume_literal!(cursor::Cursor, literal::String)
    for byte in codeunits(literal)
        _peek_byte(cursor) == byte || _fail(cursor, "invalid JSON literal")
        cursor.position += 1
    end
    return nothing
end

"""
    _after_item!(cursor, closing)

Consume the separator following an array element or object member. Return
`true` when another item follows and `false` after consuming `closing`.
"""
function _after_item!(cursor::Cursor, closing::UInt8)
    _skip_whitespace!(cursor)
    byte = _peek_byte(cursor)
    if byte == closing
        cursor.position += 1
        return false
    end
    byte == UInt8(',') || _fail(cursor, "expected ',' or collection terminator")
    cursor.position += 1
    _skip_whitespace!(cursor)
    _peek_byte(cursor) == closing && _fail(cursor, "trailing commas are not valid JSON")
    return true
end

"""
    _hex_value(byte)

Return the numeric value of an ASCII hexadecimal digit, or `-1` for a
non-hexadecimal byte.
"""
function _hex_value(byte::UInt8)
    UInt8('0') <= byte <= UInt8('9') && return Int(byte - UInt8('0'))
    UInt8('a') <= byte <= UInt8('f') && return Int(byte - UInt8('a')) + 10
    UInt8('A') <= byte <= UInt8('F') && return Int(byte - UInt8('A')) + 10
    return -1
end

"""
    _parse_hex4!(cursor)

Consume four hexadecimal digits and return the represented UTF-16 code unit.
"""
function _parse_hex4!(cursor::Cursor)
    value = UInt32(0)
    for _ in 1:4
        digit = _hex_value(_take_byte!(cursor))
        digit >= 0 || _fail(cursor, "invalid hexadecimal digit in Unicode escape")
        value = (value << 4) | UInt32(digit)
    end
    return value
end

"""
    _append_codepoint!(output, codepoint)

Append one Unicode scalar value to a UTF-8 byte buffer.
"""
function _append_codepoint!(output::Vector{UInt8}, codepoint::UInt32)
    if codepoint <= 0x7f
        push!(output, UInt8(codepoint))
    elseif codepoint <= 0x7ff
        push!(output, UInt8(0xc0 | (codepoint >> 6)))
        push!(output, UInt8(0x80 | (codepoint & 0x3f)))
    elseif codepoint <= 0xffff
        push!(output, UInt8(0xe0 | (codepoint >> 12)))
        push!(output, UInt8(0x80 | ((codepoint >> 6) & 0x3f)))
        push!(output, UInt8(0x80 | (codepoint & 0x3f)))
    else
        push!(output, UInt8(0xf0 | (codepoint >> 18)))
        push!(output, UInt8(0x80 | ((codepoint >> 12) & 0x3f)))
        push!(output, UInt8(0x80 | ((codepoint >> 6) & 0x3f)))
        push!(output, UInt8(0x80 | (codepoint & 0x3f)))
    end
    return nothing
end

"""
    _take_utf8_continuation!(cursor, lower, upper)

Consume a UTF-8 continuation byte constrained to the inclusive range
`lower:upper`.
"""
function _take_utf8_continuation!(cursor::Cursor, lower::UInt8, upper::UInt8)
    byte = _take_byte!(cursor)
    lower <= byte <= upper || _fail(cursor, "invalid UTF-8 in JSON string")
    return byte
end

"""
    _append_raw_utf8!(output, cursor, lead)

Validate and copy a raw multi-byte UTF-8 sequence whose leading byte has
already been consumed. The special second-byte ranges reject overlong forms,
surrogates, and code points above U+10FFFF.
"""
function _append_raw_utf8!(output::Vector{UInt8}, cursor::Cursor, lead::UInt8)
    push!(output, lead)
    if 0xc2 <= lead <= 0xdf
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    elseif lead == 0xe0
        push!(output, _take_utf8_continuation!(cursor, 0xa0, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    elseif 0xe1 <= lead <= 0xec || 0xee <= lead <= 0xef
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    elseif lead == 0xed
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0x9f))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    elseif lead == 0xf0
        push!(output, _take_utf8_continuation!(cursor, 0x90, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    elseif 0xf1 <= lead <= 0xf3
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    elseif lead == 0xf4
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0x8f))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
        push!(output, _take_utf8_continuation!(cursor, 0x80, 0xbf))
    else
        _fail(cursor, "invalid UTF-8 leading byte in JSON string")
    end
    return nothing
end

"""
    _append_unicode_escape!(output, cursor)

Decode a `\\uXXXX` escape, combining a valid UTF-16 surrogate pair when
required, and append its UTF-8 representation.
"""
function _append_unicode_escape!(output::Vector{UInt8}, cursor::Cursor)
    first = _parse_hex4!(cursor)
    if 0xd800 <= first <= 0xdbff
        _expect_byte!(cursor, UInt8('\\'), "high surrogate must be followed by a low surrogate")
        _expect_byte!(cursor, UInt8('u'), "high surrogate must be followed by a low surrogate")
        second = _parse_hex4!(cursor)
        0xdc00 <= second <= 0xdfff || _fail(cursor, "invalid low surrogate")
        codepoint = UInt32(0x10000) + ((first - UInt32(0xd800)) << 10) +
                    (second - UInt32(0xdc00))
        _append_codepoint!(output, codepoint)
    elseif 0xdc00 <= first <= 0xdfff
        _fail(cursor, "low surrogate without a preceding high surrogate")
    else
        _append_codepoint!(output, first)
    end
    return nothing
end

"""
    _append_escape!(output, cursor)

Decode one JSON backslash escape into `output`.
"""
function _append_escape!(output::Vector{UInt8}, cursor::Cursor)
    escaped = _take_byte!(cursor)
    if escaped == UInt8('"') || escaped == UInt8('\\') || escaped == UInt8('/')
        push!(output, escaped)
    elseif escaped == UInt8('b')
        push!(output, 0x08)
    elseif escaped == UInt8('f')
        push!(output, 0x0c)
    elseif escaped == UInt8('n')
        push!(output, 0x0a)
    elseif escaped == UInt8('r')
        push!(output, 0x0d)
    elseif escaped == UInt8('t')
        push!(output, 0x09)
    elseif escaped == UInt8('u')
        _append_unicode_escape!(output, cursor)
    else
        _fail(cursor, "invalid escape sequence")
    end
    return nothing
end

"""
    _parse_string!(cursor)

Parse a JSON string, validating raw UTF-8 and decoding every JSON escape.
"""
function _parse_string!(cursor::Cursor)
    _expect_byte!(cursor, UInt8('"'), "expected a JSON string")
    output = UInt8[]
    while true
        _at_end(cursor) && _fail(cursor, "unterminated JSON string")
        byte = _take_byte!(cursor)
        if byte == UInt8('"')
            return String(output)
        elseif byte == UInt8('\\')
            _append_escape!(output, cursor)
        elseif byte < 0x20
            _fail(cursor, "unescaped control character in JSON string")
        elseif byte < 0x80
            push!(output, byte)
        else
            _append_raw_utf8!(output, cursor, byte)
        end
    end
end

"""
    NumberToken

Byte range and decimal metadata for one syntactically valid JSON number.
`mantissa_last` excludes the exponent, while `fraction_digits` and `exponent`
allow exact integer conversion without a floating-point intermediate.
"""
struct NumberToken
    first::Int
    last::Int
    mantissa_last::Int
    fraction_digits::Int
    exponent::Int
    negative::Bool
end

"""
    _is_digit(byte)

Return whether `byte` is an ASCII decimal digit.
"""
_is_digit(byte::UInt8) = UInt8('0') <= byte <= UInt8('9')

"""
    _scan_exponent!(cursor)

Parse a validated decimal exponent. Its magnitude is saturated because values
above this bound already overflow every supported fixed-width number.
"""
function _scan_exponent!(cursor::Cursor)
    negative = false
    byte = _peek_byte(cursor)
    if byte == UInt8('+') || byte == UInt8('-')
        negative = byte == UInt8('-')
        cursor.position += 1
    end
    _is_digit(_peek_byte(cursor)) || _fail(cursor, "JSON exponent requires a digit")
    value = 0
    while _is_digit(_peek_byte(cursor))
        digit = Int(_take_byte!(cursor) - UInt8('0'))
        value = min(10_000, value * 10 + digit)
    end
    return negative ? -value : value
end

"""
    _scan_number!(cursor)

Consume one number according to the strict RFC 8259 grammar and return its
source range and decimal metadata.
"""
function _scan_number!(cursor::Cursor)
    first = cursor.position
    negative = false
    if _peek_byte(cursor) == UInt8('-')
        negative = true
        cursor.position += 1
    end

    byte = _peek_byte(cursor)
    if byte == UInt8('0')
        cursor.position += 1
        _is_digit(_peek_byte(cursor)) && _fail(cursor, "leading zeros are not valid JSON numbers")
    elseif UInt8('1') <= byte <= UInt8('9')
        cursor.position += 1
        while _is_digit(_peek_byte(cursor))
            cursor.position += 1
        end
    else
        _fail(cursor, "expected a JSON number")
    end

    fraction_digits = 0
    if _peek_byte(cursor) == UInt8('.')
        cursor.position += 1
        _is_digit(_peek_byte(cursor)) || _fail(cursor, "JSON fraction requires a digit")
        while _is_digit(_peek_byte(cursor))
            cursor.position += 1
            fraction_digits += 1
        end
    end
    mantissa_last = cursor.position - 1

    exponent = 0
    byte = _peek_byte(cursor)
    if byte == UInt8('e') || byte == UInt8('E')
        cursor.position += 1
        exponent = _scan_exponent!(cursor)
    end
    return NumberToken(
        first,
        cursor.position - 1,
        mantissa_last,
        fraction_digits,
        exponent,
        negative,
    )
end

"""
    _parse_float_token(cursor, token, T)

Convert a scanned number to a supported IEEE floating-point type, rejecting
overflow to a non-finite value.
"""
function _parse_float_token(cursor::Cursor, token::NumberToken, ::Type{T}) where {T}
    text = SubString(cursor.source, token.first, token.last)
    value = Base.tryparse(T, text)
    value === nothing && _fail(cursor, "number cannot be represented by the target float")
    isfinite(value) || _fail(cursor, "JSON number overflows the target float")
    return value
end

"""
    _mantissa_digits(cursor, token)

Return the decimal mantissa digits with sign and decimal point removed.
"""
function _mantissa_digits(cursor::Cursor, token::NumberToken)
    digits = UInt8[]
    for index in token.first:token.mantissa_last
        byte = codeunit(cursor.source, index)
        _is_digit(byte) && push!(digits, byte - UInt8('0'))
    end
    return digits
end

"""
    _integer_magnitude_limit(T, negative)

Return the largest unsigned magnitude representable by fixed-width integer
`T` with the requested sign.
"""
function _integer_magnitude_limit(::Type{T}, negative::Bool) where {T}
    if T <: Signed
        return UInt128(typemax(T)) + UInt128(negative)
    end
    return UInt128(typemax(T))
end

"""
    _checked_decimal_digit(cursor, magnitude, digit, limit)

Append one decimal digit while checking against an unsigned magnitude limit.
"""
function _checked_decimal_digit(
    cursor::Cursor,
    magnitude::UInt128,
    digit::UInt8,
    limit::UInt128,
)
    magnitude > (limit - UInt128(digit)) ÷ UInt128(10) &&
        _fail(cursor, "JSON number overflows the target integer")
    return magnitude * UInt128(10) + UInt128(digit)
end

"""
    _parse_integer_token(cursor, token, T)

Convert a decimal token exactly to fixed-width integer `T`. Fractional zeros
and exponents are handled in decimal space, avoiding loss through `Float64`.
"""
function _parse_integer_token(cursor::Cursor, token::NumberToken, ::Type{T}) where {T}
    digits = _mantissa_digits(cursor, token)
    all_zero = all(iszero, digits)
    all_zero && return zero(T)

    scale = token.exponent - token.fraction_digits
    kept = length(digits)
    appended_zeros = 0
    if scale < 0
        removed = -scale
        removed >= kept && _fail(cursor, "JSON number is not an exact integer")
        for index in (kept - removed + 1):kept
            iszero(digits[index]) || _fail(cursor, "JSON number is not an exact integer")
        end
        kept -= removed
    else
        appended_zeros = scale
    end

    token.negative && T <: Unsigned &&
        _fail(cursor, "negative JSON number cannot be represented by an unsigned integer")
    limit = _integer_magnitude_limit(T, token.negative)
    magnitude = UInt128(0)
    for index in 1:kept
        magnitude = _checked_decimal_digit(cursor, magnitude, digits[index], limit)
    end
    for _ in 1:appended_zeros
        magnitude = _checked_decimal_digit(cursor, magnitude, 0x00, limit)
    end

    if token.negative
        magnitude == UInt128(typemax(T)) + UInt128(1) && return typemin(T)
        return -T(magnitude)
    end
    return T(magnitude)
end

"""
    _parse_untyped_value!(cursor)

Parse one value into the closed `JSONValue` representation.
"""
function _parse_untyped_value!(cursor::Cursor)
    _skip_whitespace!(cursor)
    byte = _peek_byte(cursor)
    if byte == UInt8('n')
        _consume_literal!(cursor, "null")
        return JSONValue(nothing)
    elseif byte == UInt8('t')
        _consume_literal!(cursor, "true")
        return JSONValue(true)
    elseif byte == UInt8('f')
        _consume_literal!(cursor, "false")
        return JSONValue(false)
    elseif byte == UInt8('"')
        return JSONValue(_parse_string!(cursor))
    elseif byte == UInt8('[')
        return JSONValue(_parse_untyped_array!(cursor))
    elseif byte == UInt8('{')
        return JSONValue(_parse_untyped_object!(cursor))
    elseif byte == UInt8('-') || _is_digit(byte)
        token = _scan_number!(cursor)
        return JSONValue(_parse_float_token(cursor, token, Float64))
    end
    _fail(cursor, "expected a JSON value")
end

"""
    _parse_untyped_array!(cursor)

Parse a JSON array into `Vector{JSONValue}`.
"""
function _parse_untyped_array!(cursor::Cursor)
    _expect_byte!(cursor, UInt8('['), "expected a JSON array")
    values = JSONValue[]
    _skip_whitespace!(cursor)
    if _peek_byte(cursor) == UInt8(']')
        cursor.position += 1
        return values
    end
    while true
        push!(values, _parse_untyped_value!(cursor))
        _after_item!(cursor, UInt8(']')) || return values
    end
end

"""
    _parse_untyped_object!(cursor)

Parse a JSON object into `Dict{String,JSONValue}`, rejecting duplicate decoded
keys before inserting their values.
"""
function _parse_untyped_object!(cursor::Cursor)
    _expect_byte!(cursor, UInt8('{'), "expected a JSON object")
    values = Dict{String,JSONValue}()
    _skip_whitespace!(cursor)
    if _peek_byte(cursor) == UInt8('}')
        cursor.position += 1
        return values
    end
    while true
        _peek_byte(cursor) == UInt8('"') || _fail(cursor, "object keys must be JSON strings")
        key = _parse_string!(cursor)
        haskey(values, key) && _fail(cursor, "duplicate object key '$key'")
        _skip_whitespace!(cursor)
        _expect_byte!(cursor, UInt8(':'), "expected ':' after object key")
        values[key] = _parse_untyped_value!(cursor)
        _after_item!(cursor, UInt8('}')) || return values
    end
end
