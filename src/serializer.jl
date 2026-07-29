"""
    SerializationError(message)

Exception raised when a Julia value cannot be represented by the supported JSON
serialization grammar.
"""
struct SerializationError <: Exception
    message::String
end

"""
    Base.showerror(io, error::SerializationError)

Render a JSON serialization error.
"""
function Base.showerror(io::IO, error::SerializationError)
    print(io, "StaticJSON.SerializationError: ", error.message)
end

"""
    JSONWriter(indentation)

Mutable output state for serialization. `indentation == -1` selects compact
output; nonnegative values select pretty output with that many spaces per level.
"""
mutable struct JSONWriter
    output::Vector{UInt8}
    indentation::Int
    depth::Int
end

"""
    JSONWriter(indentation::Int)

Create an empty writer with the requested internal indentation setting.
"""
JSONWriter(indentation::Int) = JSONWriter(UInt8[], indentation, 0)

"""
    _serialization_fail(message)

Throw a `SerializationError` with `message`.
"""
_serialization_fail(message::String) = throw(SerializationError(message))

"""
    _indent_width(indent)

Validate the public `indent` keyword and return `-1` for compact output or a
nonnegative machine integer for pretty output.
"""
function _indent_width(::Nothing)
    return -1
end

function _indent_width(indent::Integer)
    indent isa Bool && throw(ArgumentError("indent must be a nonnegative integer or nothing"))
    indent < 0 && throw(ArgumentError("indent must be nonnegative"))
    indent > typemax(Int) && throw(ArgumentError("indent is too large"))
    return Int(indent)
end

function _indent_width(indent)
    throw(ArgumentError("indent must be a nonnegative integer or nothing"))
end

"""
    _append_ascii!(writer, text)

Append an ASCII string known to contain JSON syntax or a formatted number.
"""
function _append_ascii!(writer::JSONWriter, text::String)
    append!(writer.output, codeunits(text))
    return nothing
end

"""
    _write_newline_indent!(writer)

Write a newline followed by indentation for the writer's current depth.
"""
function _write_newline_indent!(writer::JSONWriter)
    push!(writer.output, UInt8('\n'))
    for _ in 1:writer.depth
        for _ in 1:writer.indentation
            push!(writer.output, UInt8(' '))
        end
    end
    return nothing
end

"""
    _open_collection!(writer, opening)

Write an array or object opening byte and enter its indentation level.
"""
function _open_collection!(writer::JSONWriter, opening::UInt8)
    push!(writer.output, opening)
    writer.depth += 1
    return nothing
end

"""
    _before_item!(writer, first)

Write the comma, newline, and indentation preceding a collection item. Return
`false`, which callers retain as their updated `first` flag.
"""
function _before_item!(writer::JSONWriter, first::Bool)
    first || push!(writer.output, UInt8(','))
    writer.indentation >= 0 && _write_newline_indent!(writer)
    return false
end

"""
    _close_collection!(writer, closing, nonempty)

Leave a collection indentation level and write its closing byte. Pretty output
places a nonempty collection's closing byte on its own line.
"""
function _close_collection!(writer::JSONWriter, closing::UInt8, nonempty::Bool)
    writer.depth -= 1
    nonempty && writer.indentation >= 0 && _write_newline_indent!(writer)
    push!(writer.output, closing)
    return nothing
end

"""
    _write_name_separator!(writer)

Write the colon between an object name and value, including one space in pretty
output.
"""
function _write_name_separator!(writer::JSONWriter)
    push!(writer.output, UInt8(':'))
    writer.indentation >= 0 && push!(writer.output, UInt8(' '))
    return nothing
end

"""
    _hex_digit(value)

Return the lowercase ASCII hexadecimal digit for a value in `0:15`.
"""
function _hex_digit(value::UInt8)
    value < 0x0a && return UInt8('0') + value
    return UInt8('a') + (value - 0x0a)
end

"""
    _append_control_escape!(writer, byte)

Write a JSON escape for an ASCII control byte.
"""
function _append_control_escape!(writer::JSONWriter, byte::UInt8)
    push!(writer.output, UInt8('\\'))
    if byte == 0x08
        push!(writer.output, UInt8('b'))
    elseif byte == 0x0c
        push!(writer.output, UInt8('f'))
    elseif byte == 0x0a
        push!(writer.output, UInt8('n'))
    elseif byte == 0x0d
        push!(writer.output, UInt8('r'))
    elseif byte == 0x09
        push!(writer.output, UInt8('t'))
    else
        push!(writer.output, UInt8('u'))
        push!(writer.output, UInt8('0'))
        push!(writer.output, UInt8('0'))
        push!(writer.output, _hex_digit(byte >> 4))
        push!(writer.output, _hex_digit(byte & 0x0f))
    end
    return nothing
end

"""
    _take_serialized_continuation!(writer, value, position, lower, upper)

Validate and append one UTF-8 continuation byte, returning the next source byte
position.
"""
function _take_serialized_continuation!(
    writer::JSONWriter,
    value::String,
    position::Int,
    lower::UInt8,
    upper::UInt8,
)
    position <= ncodeunits(value) || _serialization_fail("invalid UTF-8 in string")
    byte = codeunit(value, position)
    lower <= byte <= upper || _serialization_fail("invalid UTF-8 in string")
    push!(writer.output, byte)
    return position + 1
end

"""
    _append_serialized_utf8!(writer, value, position, lead)

Validate and copy a raw multi-byte UTF-8 sequence. `position` points to the byte
after `lead`; the returned position points after the complete sequence.
"""
function _append_serialized_utf8!(
    writer::JSONWriter,
    value::String,
    position::Int,
    lead::UInt8,
)
    push!(writer.output, lead)
    if 0xc2 <= lead <= 0xdf
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    elseif lead == 0xe0
        position = _take_serialized_continuation!(writer, value, position, 0xa0, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    elseif 0xe1 <= lead <= 0xec || 0xee <= lead <= 0xef
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    elseif lead == 0xed
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0x9f)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    elseif lead == 0xf0
        position = _take_serialized_continuation!(writer, value, position, 0x90, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    elseif 0xf1 <= lead <= 0xf3
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    elseif lead == 0xf4
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0x8f)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
        position = _take_serialized_continuation!(writer, value, position, 0x80, 0xbf)
    else
        _serialization_fail("invalid UTF-8 leading byte in string")
    end
    return position
end

"""
    _write_string!(writer, value)

Write a validated Julia `String` using JSON escaping rules.
"""
function _write_string!(writer::JSONWriter, value::String)
    push!(writer.output, UInt8('"'))
    position = 1
    limit = ncodeunits(value)
    while position <= limit
        byte = codeunit(value, position)
        position += 1
        if byte == UInt8('"') || byte == UInt8('\\')
            push!(writer.output, UInt8('\\'))
            push!(writer.output, byte)
        elseif byte < 0x20
            _append_control_escape!(writer, byte)
        elseif byte < 0x80
            push!(writer.output, byte)
        else
            position = _append_serialized_utf8!(writer, value, position, byte)
        end
    end
    push!(writer.output, UInt8('"'))
    return nothing
end

"""
    _serializable_union_expr(T, value, seen)

Build a writer expression for a supported sentinel union. `missing` is an error
outside an object-member omission check.
"""
function _serializable_union_expr(T, value, seen::Tuple)
    members = Base.uniontypes(T)
    ordinary = filter(member -> member !== Missing && member !== Nothing, members)
    length(ordinary) <= 1 ||
        return :(_serialization_fail("general union values are not supported"))
    payload = isempty(ordinary) ? nothing : only(ordinary)
    allows_missing = Missing in members
    allows_nothing = Nothing in members
    payload_expr = payload === nothing ? nothing : _serializer_expr(payload, value, seen)

    missing_branch = allows_missing ?
                     :($value === missing &&
                       _serialization_fail("missing is only valid as an omitted object member")) :
                     nothing
    if payload === nothing
        value_expr = :(_write_value!(writer, nothing))
    elseif allows_nothing
        value_expr = :($value === nothing ? _write_value!(writer, nothing) : $payload_expr)
    else
        value_expr = payload_expr
    end
    return missing_branch === nothing ? value_expr : quote
        $missing_branch
        $value_expr
    end
end

"""
    _serializable_array_expr(T, value, seen)

Build an array writer for a concrete vector-like type with element type `T`.
"""
function _serializable_array_expr(T, value, seen::Tuple)
    item = gensym(:item)
    first = gensym(:first)
    item_expr = _serializer_expr(T, item, seen)
    return quote
        _open_collection!(writer, UInt8('['))
        $first = true
        for $item in $value
            $first = _before_item!(writer, $first)
            $item_expr
        end
        _close_collection!(writer, UInt8(']'), !$first)
    end
end

"""
    _serializable_tuple_expr(T, value, seen)

Build an unrolled array writer for a concrete tuple type.
"""
function _serializable_tuple_expr(T, value, seen::Tuple)
    first = gensym(:first)
    statements = Expr[
        :(_open_collection!(writer, UInt8('['))),
        :($first = true),
    ]
    for (index, fieldtype) in enumerate(fieldtypes(T))
        fieldvalue = :(getfield($value, $index))
        push!(statements, :($first = _before_item!(writer, $first)))
        push!(statements, _serializer_expr(fieldtype, fieldvalue, seen))
    end
    push!(statements, :(_close_collection!(writer, UInt8(']'), !$first)))
    return Expr(:block, statements...)
end

"""
    _serializable_present_expr(T, value, seen)

Build an object-value writer after a surrounding check has excluded `missing`.
"""
function _serializable_present_expr(T, value, seen::Tuple)
    T isa Union || return _serializer_expr(T, value, seen)
    members = Base.uniontypes(T)
    ordinary = filter(member -> member !== Missing && member !== Nothing, members)
    length(ordinary) <= 1 ||
        return :(_serialization_fail("general union values are not supported"))
    payload = isempty(ordinary) ? nothing : only(ordinary)
    allows_nothing = Nothing in members
    if payload === nothing
        return :(_write_value!(writer, nothing))
    end
    payload_expr = _serializer_expr(payload, value, seen)
    return allows_nothing ?
           :($value === nothing ? _write_value!(writer, nothing) : $payload_expr) :
           payload_expr
end

"""
    _serializable_dict_expr(T, value, seen)

Build an object writer for `Dict{String,T}`, omitting entries whose value is
`missing`.
"""
function _serializable_dict_expr(T, value, seen::Tuple)
    key = gensym(:key)
    item = gensym(:item)
    first = gensym(:first)
    present_expr = _serializable_present_expr(T, item, seen)
    write_item = quote
        $first = _before_item!(writer, $first)
        _write_string!(writer, $key)
        _write_name_separator!(writer)
        $present_expr
    end
    body = Missing <: T ? :($item === missing || $write_item) : write_item
    return quote
        _open_collection!(writer, UInt8('{'))
        $first = true
        for ($key, $item) in $value
            $body
        end
        _close_collection!(writer, UInt8('}'), !$first)
    end
end

"""
    _serializable_object_expr(T, value, seen)

Build an object writer for a concrete struct or `NamedTuple`, preserving field
declaration order and omitting fields whose value is `missing`.
"""
function _serializable_object_expr(T, value, seen::Tuple)
    first = gensym(:first)
    statements = Expr[
        :(_open_collection!(writer, UInt8('{'))),
        :($first = true),
    ]
    for (index, (name, fieldtype)) in enumerate(zip(fieldnames(T), fieldtypes(T)))
        fieldvalue = gensym(name)
        present_expr = _serializable_present_expr(fieldtype, fieldvalue, seen)
        write_field = quote
            $first = _before_item!(writer, $first)
            _write_string!(writer, $(String(name)))
            _write_name_separator!(writer)
            $present_expr
        end
        push!(statements, :($fieldvalue = getfield($value, $index)))
        if Missing <: fieldtype
            push!(statements, :($fieldvalue === missing || $write_field))
        else
            push!(statements, write_field)
        end
    end
    push!(statements, :(_close_collection!(writer, UInt8('}'), !$first)))
    return Expr(:block, statements...)
end

"""
    _serializer_expr(T, value, seen=())

Select and build the statically dispatched writer expression for type `T`.
Acyclic composite schemas are embedded, while repeated recursive struct types
fall back to the already generated writer method.
"""
function _serializer_expr(T, value, seen::Tuple = ())
    if T === JSONValue || T === Nothing || T === Missing || T === Bool || T === String ||
       T <: FixedInteger || T <: FixedFloat
        return :(_write_value!(writer, $value))
    elseif T isa Union
        return _serializable_union_expr(T, value, seen)
    elseif T isa DataType && T <: AbstractVector
        return _serializable_array_expr(eltype(T), value, seen)
    elseif T isa DataType && T <: Dict && keytype(T) === String
        return _serializable_dict_expr(valtype(T), value, seen)
    elseif T isa DataType && T <: Tuple
        return _serializable_tuple_expr(T, value, seen)
    elseif T isa DataType && T <: NamedTuple
        T in seen && return :(_write_value!(writer, $value))
        return _serializable_object_expr(T, value, (seen..., T))
    elseif T isa DataType && isstructtype(T) && !isprimitivetype(T)
        T in seen && return :(_write_value!(writer, $value))
        return _serializable_object_expr(T, value, (seen..., T))
    end
    return :(_serialization_fail("unsupported value type"))
end

"""
    _serializable_type_error(T, seen=())

Return `nothing` when `T` belongs to the supported serialization grammar, or a
human-readable error otherwise. This mirrors typed parsing while excluding
Julia runtime singleton types such as `Symbol` and `Module`.
"""
function _serializable_type_error(T, seen::Tuple = ())
    if T === JSONValue || T === Nothing || T === Missing || T === Bool || T === String
        return nothing
    elseif T === Union{}
        return "empty union value types are not supported"
    elseif T isa Union
        members = Base.uniontypes(T)
        ordinary = filter(member -> member !== Missing && member !== Nothing, members)
        length(ordinary) <= 1 || return "general union value types are not supported"
        return isempty(ordinary) ? nothing : _serializable_type_error(only(ordinary), seen)
    elseif T <: FixedInteger || T <: FixedFloat
        return nothing
    elseif T isa UnionAll || !(T isa DataType)
        return "value type must be fully specified"
    elseif T <: AbstractVector
        isconcretetype(T) || return "AbstractVector value types must be concrete"
        return _serializable_type_error(eltype(T), seen)
    elseif T <: AbstractArray
        return "only one-dimensional vector values are supported"
    elseif T <: Dict
        keytype(T) === String || return "JSON object dictionaries require String keys"
        return _serializable_type_error(valtype(T), seen)
    elseif T <: AbstractDict
        return "only Dict{String,T} object values are supported"
    elseif T <: Tuple
        for fieldtype in fieldtypes(T)
            error = _serializable_type_error(fieldtype, seen)
            error === nothing || return error
        end
        return nothing
    elseif T <: NamedTuple
        for fieldtype in fieldtypes(T)
            error = _serializable_type_error(fieldtype, seen)
            error === nothing || return error
        end
        return nothing
    elseif !isconcretetype(T)
        return "value type must be concrete"
    elseif T === Symbol || T === Module || T <: Number || T <: AbstractString || T <: Enum ||
           isprimitivetype(T)
        return "unsupported value type"
    end
    T in seen && return nothing
    nested_seen = (seen..., T)
    for fieldtype in fieldtypes(T)
        error = _serializable_type_error(fieldtype, nested_seen)
        error === nothing || return error
    end
    return nothing
end

"""
    _validate_serializable!(writer, T)

Validate the complete static value graph before writing any output.
"""
@generated function _validate_serializable!(writer::JSONWriter, ::Type{T}) where {T}
    error = _serializable_type_error(T)
    return error === nothing ? :(nothing) : :(_serialization_fail($error))
end

"""
    _write_value!(writer, value)

Write one supported Julia value as JSON. Primitive methods are direct, while a
generated fallback handles composite schemas.
"""
function _write_value!(writer::JSONWriter, ::Nothing)
    _append_ascii!(writer, "null")
end

function _write_value!(writer::JSONWriter, value::Bool)
    _append_ascii!(writer, value ? "true" : "false")
end

function _write_value!(writer::JSONWriter, value::String)
    _write_string!(writer, value)
end

function _write_value!(writer::JSONWriter, value::T) where {T<:FixedInteger}
    _append_ascii!(writer, string(value))
end

function _write_value!(writer::JSONWriter, value::T) where {T<:FixedFloat}
    isfinite(value) || _serialization_fail("non-finite floats are not valid JSON numbers")
    _append_ascii!(writer, string(value))
end

function _write_value!(writer::JSONWriter, ::Missing)
    _serialization_fail("missing is only valid as an omitted object member")
end

function _write_value!(writer::JSONWriter, value::JSONValue)
    payload = unwrap(value)
    if payload === nothing
        _write_value!(writer, nothing)
    elseif payload isa Bool
        _write_value!(writer, payload)
    elseif payload isa Float64
        _write_value!(writer, payload)
    elseif payload isa String
        _write_value!(writer, payload)
    elseif payload isa Vector{JSONValue}
        _write_value!(writer, payload)
    else
        _write_value!(writer, payload::Dict{String,JSONValue})
    end
    return nothing
end

"""
    _write_composite!(writer, value)

Execute the generated writer for a composite value type.
"""
@generated function _write_composite!(writer::JSONWriter, value::T) where {T}
    expression = _serializer_expr(T, :value)
    return quote
        $expression
        return nothing
    end
end

function _write_value!(writer::JSONWriter, value)
    _write_composite!(writer, value)
end

"""
    json(value; indent=nothing)

Serialize a supported Julia value to a JSON `String`. `indent=nothing` produces
compact output without structural line breaks. A nonnegative integer enables
pretty output with that many spaces per nesting level.
"""
function json(value; indent = nothing)
    writer = JSONWriter(_indent_width(indent))
    _validate_serializable!(writer, typeof(value))
    _write_value!(writer, value)
    return String(writer.output)
end
