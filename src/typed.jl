"Fixed-width integer targets supported by the typed decoder."
const FixedInteger = Union{Int8,Int16,Int32,Int64,Int128,UInt8,UInt16,UInt32,UInt64,UInt128}

"IEEE floating-point targets supported by the typed decoder."
const FixedFloat = Union{Float16,Float32,Float64}

"""
    _target_error(T, seen=())

Return `nothing` when `T` belongs to the supported static target grammar, or a
human-readable error otherwise. The `seen` tuple terminates validation of
recursive struct definitions without introducing an abstractly typed set.
"""
function _target_error(T, seen::Tuple = ())
    if T === JSONValue || T === Nothing || T === Missing || T === Bool || T === String
        return nothing
    elseif T === Union{}
        return "empty union target types are not supported"
    elseif T isa Union
        members = Base.uniontypes(T)
        ordinary = filter(member -> member !== Missing && member !== Nothing, members)
        length(ordinary) <= 1 || return "general union target types are not supported"
        return isempty(ordinary) ? nothing : _target_error(only(ordinary), seen)
    elseif T <: FixedInteger || T <: FixedFloat
        return nothing
    elseif T isa UnionAll || !(T isa DataType)
        return "target type must be fully specified"
    elseif T <: Vector
        return _target_error(eltype(T), seen)
    elseif T <: AbstractVector
        isconcretetype(T) || return "converted AbstractVector targets must be concrete"
        return _target_error(eltype(T), seen)
    elseif T <: AbstractArray
        return "only one-dimensional Vector targets are supported"
    elseif T <: Dict
        keytype(T) === String || return "JSON object dictionaries require String keys"
        return _target_error(valtype(T), seen)
    elseif T <: AbstractDict
        return "only Dict{String,T} object targets are supported"
    elseif T <: Tuple
        any(parameter -> parameter isa Core.TypeofVararg, T.parameters) &&
            return "unbounded tuple targets are not supported"
        for parameter in T.parameters
            error = _target_error(parameter, seen)
            error === nothing || return error
        end
        return nothing
    elseif T <: NamedTuple
        for fieldtype in fieldtypes(T)
            error = _target_error(fieldtype, seen)
            error === nothing || return error
        end
        return nothing
    elseif !isconcretetype(T)
        return "target type must be concrete"
    elseif T <: Number || T <: AbstractString || T <: Enum || isprimitivetype(T)
        return "unsupported target type"
    end
    T in seen && return nothing
    nested_seen = (seen..., T)
    for fieldtype in fieldtypes(T)
        error = _target_error(fieldtype, nested_seen)
        error === nothing || return error
    end
    return nothing
end

"""
    _validate_target!(cursor, T)

Validate the complete target graph at specialization time and emit no runtime
work for supported types.
"""
@generated function _validate_target!(cursor::Cursor, ::Type{T}) where {T}
    error = _target_error(T)
    return error === nothing ? :(nothing) : :(_fail(cursor, $error))
end

"""
    _expect_value_kind(cursor, expected)

Throw a type-mismatch error stating which JSON kind was expected.
"""
function _expect_value_kind(cursor::Cursor, expected::String)
    _fail(cursor, "expected $expected for the requested target type")
end

"""
    _vector_decoder_expr(T, seen=())

Build an embeddable array decoder for element type `T`. The expression yields
the completed vector without `return`, allowing generated object decoders to
inline it without changing their control flow.
"""
function _vector_decoder_expr(T, seen::Tuple = ())
    element_decoder = _direct_decoder_expr(T, seen)
    values = gensym(:values)
    return quote
        _skip_whitespace!(cursor)
        _peek_byte(cursor) == UInt8('[') || _expect_value_kind(cursor, "an array")
        _expect_byte!(cursor, UInt8('['), "expected a JSON array")
        $values = Vector{$T}()
        _skip_whitespace!(cursor)
        if _peek_byte(cursor) == UInt8(']')
            cursor.position += 1
        else
            while true
                push!($values, $element_decoder)
                _after_item!(cursor, UInt8(']')) || break
            end
        end
        $values
    end
end

"""
    _converted_vector_decoder_expr(T, seen=())

Build an embeddable decoder for a concrete `AbstractVector` target `T`. JSON
elements are first parsed into `Vector{eltype(T)}` before the standard
`convert(T, values)` protocol constructs the requested representation.
"""
function _converted_vector_decoder_expr(T, seen::Tuple = ())
    vector_decoder = _vector_decoder_expr(eltype(T), seen)
    values = gensym(:values)
    converted = gensym(:converted)
    return quote
        $values = $vector_decoder
        $converted = convert($T, $values)
        $converted isa $T ||
            _fail(cursor, "vector conversion did not return the requested target type")
        $converted
    end
end

"""
    _dict_decoder_expr(T, seen=())

Build an embeddable object decoder for `Dict{String,T}`. As with vectors, the
value decoder is selected and embedded while specializing the surrounding
schema.
"""
function _dict_decoder_expr(T, seen::Tuple = ())
    value_decoder = _direct_decoder_expr(T, seen)
    values = gensym(:values)
    key = gensym(:key)
    return quote
        _skip_whitespace!(cursor)
        _peek_byte(cursor) == UInt8('{') || _expect_value_kind(cursor, "an object")
        _expect_byte!(cursor, UInt8('{'), "expected a JSON object")
        $values = Dict{String,$T}()
        _skip_whitespace!(cursor)
        if _peek_byte(cursor) == UInt8('}')
            cursor.position += 1
        else
            while true
                _peek_byte(cursor) == UInt8('"') ||
                    _fail(cursor, "object keys must be JSON strings")
                $key = _parse_string!(cursor)
                haskey($values, $key) &&
                    _fail(cursor, string("duplicate object key '", $key, "'"))
                _skip_whitespace!(cursor)
                _expect_byte!(cursor, UInt8(':'), "expected ':' after object key")
                $values[$key] = $value_decoder
                _after_item!(cursor, UInt8('}')) || break
            end
        end
        $values
    end
end

"""
    _union_decoder_expr(T, seen=())

Build an embeddable decoder for the supported `Missing`/`Nothing` sentinel
unions. General unions produce the same deterministic unsupported-target error
as the public validator.
"""
function _union_decoder_expr(T, seen::Tuple = ())
    members = Base.uniontypes(T)
    ordinary = filter(member -> member !== Missing && member !== Nothing, members)
    length(ordinary) <= 1 ||
        return :(_fail(cursor, "general union target types are not supported"))
    payload = isempty(ordinary) ? nothing : only(ordinary)
    allows_nothing = Nothing in members
    if payload === nothing
        return quote
            _skip_whitespace!(cursor)
            _peek_byte(cursor) == UInt8('n') ||
                _fail(cursor, "union target accepts only null or an absent field")
            _consume_literal!(cursor, "null")
            nothing
        end
    elseif allows_nothing
        payload_decoder = _direct_decoder_expr(payload, seen)
        return quote
            _skip_whitespace!(cursor)
            if _peek_byte(cursor) == UInt8('n')
                _consume_literal!(cursor, "null")
                nothing
            else
                $payload_decoder
            end
        end
    end
    return _direct_decoder_expr(payload, seen)
end

"""
    _direct_decoder_expr(T, seen=())

Return an expression that calls the decoder category selected for concrete
target `T`. Generated composite decoders use these direct edges instead of
recursing through the overloaded dispatcher, which prevents Julia's recursive
inference limiter from dropping deeply nested JuliaC reachability edges.
"""
function _direct_decoder_expr(T, seen::Tuple = ())
    if T isa DataType && T <: Vector
        return _vector_decoder_expr(eltype(T), seen)
    elseif T isa DataType && T <: AbstractVector
        return _converted_vector_decoder_expr(T, seen)
    elseif T isa DataType && T <: Dict && keytype(T) === String
        return _dict_decoder_expr(valtype(T), seen)
    elseif T isa DataType && T <: Tuple
        return _tuple_decoder_expr(T, seen)
    elseif T isa DataType && T <: NamedTuple
        T in seen && return :(_parse_namedtuple_value!(cursor, $T))
        return _object_decoder_expr(T, true, (seen..., T))
    elseif T isa DataType &&
           isstructtype(T) &&
           T !== JSONValue &&
           T !== Nothing &&
           T !== Missing &&
           T !== Bool &&
           T !== String &&
           !(T <: Number) &&
           !isprimitivetype(T)
        T in seen && return :(_parse_struct_value!(cursor, $T))
        return _object_decoder_expr(T, false, (seen..., T))
    elseif T isa Union
        return _union_decoder_expr(T, seen)
    end
    return :(_parse_typed_value!(cursor, $T))
end

"""
    _parse_typed_value!(cursor, T)

Parse one JSON value directly into the statically supplied target type `T`.
Specialized methods cover every supported primitive and collection target.
"""
_parse_typed_value!(cursor::Cursor, ::Type{JSONValue}) = _parse_untyped_value!(cursor)

function _parse_typed_value!(cursor::Cursor, ::Type{Nothing})
    _skip_whitespace!(cursor)
    _peek_byte(cursor) == UInt8('n') || _expect_value_kind(cursor, "null")
    _consume_literal!(cursor, "null")
    return nothing
end

function _parse_typed_value!(cursor::Cursor, ::Type{Missing})
    _skip_whitespace!(cursor)
    _fail(cursor, "Missing represents an absent object field, not a JSON value")
end

function _parse_typed_value!(cursor::Cursor, ::Type{Bool})
    _skip_whitespace!(cursor)
    byte = _peek_byte(cursor)
    if byte == UInt8('t')
        _consume_literal!(cursor, "true")
        return true
    elseif byte == UInt8('f')
        _consume_literal!(cursor, "false")
        return false
    end
    _expect_value_kind(cursor, "a Boolean")
end

function _parse_typed_value!(cursor::Cursor, ::Type{String})
    _skip_whitespace!(cursor)
    _peek_byte(cursor) == UInt8('"') || _expect_value_kind(cursor, "a string")
    return _parse_string!(cursor)
end

function _parse_typed_value!(cursor::Cursor, ::Type{T}) where {T<:FixedInteger}
    _skip_whitespace!(cursor)
    byte = _peek_byte(cursor)
    (byte == UInt8('-') || _is_digit(byte)) || _expect_value_kind(cursor, "a number")
    return _parse_integer_token(cursor, _scan_number!(cursor), T)
end

function _parse_typed_value!(cursor::Cursor, ::Type{T}) where {T<:FixedFloat}
    _skip_whitespace!(cursor)
    byte = _peek_byte(cursor)
    (byte == UInt8('-') || _is_digit(byte)) || _expect_value_kind(cursor, "a number")
    return _parse_float_token(cursor, _scan_number!(cursor), T)
end

"""
    _parse_vector_value!(cursor, T)

Parse a JSON array into `Vector{T}` using a generated direct edge to the
decoder category for `T`.
"""
@generated function _parse_vector_value!(cursor::Cursor, ::Type{T}) where {T}
    decoder = _vector_decoder_expr(T)
    return :(return $decoder)
end

_parse_typed_value!(cursor::Cursor, ::Type{Vector{T}}) where {T} =
    _parse_vector_value!(cursor, T)

"""
    _parse_dict_value!(cursor, T)

Parse a JSON object into `Dict{String,T}` using a generated direct edge to the
decoder category for `T`.
"""
@generated function _parse_dict_value!(cursor::Cursor, ::Type{T}) where {T}
    decoder = _dict_decoder_expr(T)
    return :(return $decoder)
end

_parse_typed_value!(cursor::Cursor, ::Type{Dict{String,T}}) where {T} =
    _parse_dict_value!(cursor, T)

"""
    _tuple_decoder_expr(T, seen=())

Build the fully unrolled parser body for a fixed-length tuple target. This
helper runs only while Julia specializes the generated tuple decoder.
"""
function _tuple_decoder_expr(T, seen::Tuple = ())
    T isa DataType || return :(_fail(cursor, "unbounded tuple targets are not supported"))
    parameters = T.parameters
    any(parameter -> parameter isa Core.TypeofVararg, parameters) &&
        return :(_fail(cursor, "unbounded tuple targets are not supported"))

    length_message = "tuple target requires exactly $(length(parameters)) elements"
    variables = [gensym(:element) for _ in parameters]
    statements = Expr[
        :(_skip_whitespace!(cursor)),
        :(_peek_byte(cursor) == UInt8('[') || _expect_value_kind(cursor, "an array")),
        :(_expect_byte!(cursor, UInt8('['), "expected a JSON array")),
    ]
    for (index, (variable, parameter)) in enumerate(zip(variables, parameters))
        push!(statements, :(_skip_whitespace!(cursor)))
        if index > 1
            push!(statements, :(_expect_byte!(cursor, UInt8(','), $length_message)))
            push!(statements, :(_skip_whitespace!(cursor)))
        end
        push!(
            statements,
            :(_peek_byte(cursor) == UInt8(']') && _fail(cursor, $length_message)),
        )
        decoder = _direct_decoder_expr(parameter, seen)
        push!(statements, :($variable = $decoder))
    end
    push!(statements, :(_skip_whitespace!(cursor)))
    push!(statements, :(_peek_byte(cursor) == UInt8(']') || _fail(cursor, $length_message)))
    push!(statements, :(cursor.position += 1))
    return Expr(:block, statements..., Expr(:tuple, variables...))
end

"""
    _parse_tuple_value!(cursor, T)

Parse a JSON array into a fixed-length tuple using code specialized for every
element type and position.
"""
@generated function _parse_tuple_value!(cursor::Cursor, ::Type{T}) where {T<:Tuple}
    return _tuple_decoder_expr(T)
end

function _parse_typed_value!(cursor::Cursor, ::Type{T}) where {T<:Tuple}
    return _parse_tuple_value!(cursor, T)
end

"""
    _object_decoder_expr(T, namedtuple, seen=())

Build an object parser with literal branches for every declared field. The
generated body keeps heterogeneous field slots statically typed while allowing
JSON object members to appear in any order.
"""
function _object_decoder_expr(T, namedtuple::Bool, seen::Tuple = ())
    names = map(Symbol, fieldnames(T))
    types = fieldtypes(T)
    variables = [gensym(name) for name in names]

    statements = Expr[
        :(_skip_whitespace!(cursor)),
        :(_peek_byte(cursor) == UInt8('{') || _expect_value_kind(cursor, "an object")),
        :(_expect_byte!(cursor, UInt8('{'), "expected a JSON object")),
    ]
    for variable in variables
        push!(statements, :(local $variable))
    end

    branch = :(_fail(cursor, "unknown object key '$key' for target type"))
    for index in reverse(eachindex(names))
        name = String(names[index])
        variable = variables[index]
        defined = Expr(:isdefined, variable)
        fieldtype = types[index]
        decoder = _direct_decoder_expr(fieldtype, seen)
        branch = quote
            if key == $name
                $defined && _fail(cursor, "duplicate object key '$key'")
                $variable = $decoder
            else
                $branch
            end
        end
    end

    push!(
        statements,
        quote
            _skip_whitespace!(cursor)
            if _peek_byte(cursor) == UInt8('}')
                cursor.position += 1
            else
                while true
                    _peek_byte(cursor) == UInt8('"') ||
                        _fail(cursor, "object keys must be JSON strings")
                    key = _parse_string!(cursor)
                    _skip_whitespace!(cursor)
                    _expect_byte!(cursor, UInt8(':'), "expected ':' after object key")
                    $branch # COV_EXCL_LINE: generated branches are attributed to their emitted code
                    _after_item!(cursor, UInt8('}')) || break
                end
            end
        end,
    )

    for index in eachindex(names)
        name = String(names[index])
        missing_message = "missing required object key '$name'"
        variable = variables[index]
        defined = Expr(:isdefined, variable)
        fieldtype = types[index]
        if Missing <: fieldtype
            push!(statements, :($defined || ($variable = missing)))
        else
            push!(statements, :($defined || _fail(cursor, $missing_message)))
        end
    end

    values = Expr(:tuple, variables...)
    result = namedtuple ? :($T($values)) : :($T($(variables...)))
    constructed = gensym(:constructed)
    push!(statements, :($constructed = $result))
    push!(
        statements,
        :(
            $constructed isa $T || _fail(
                cursor,
                "the positional constructor did not return the requested target type",
            )
        ),
    )
    return Expr(:block, statements..., constructed)
end

"""
    _parse_namedtuple_value!(cursor, T)

Parse a JSON object into a concrete `NamedTuple` with exact key matching.
"""
@generated function _parse_namedtuple_value!(
    cursor::Cursor,
    ::Type{T},
) where {T<:NamedTuple}
    return _object_decoder_expr(T, true, (T,))
end

function _parse_typed_value!(cursor::Cursor, ::Type{T}) where {T<:NamedTuple}
    return _parse_namedtuple_value!(cursor, T)
end

"""
    _parse_struct_value!(cursor, T)

Parse a JSON object into a concrete struct using its compile-time field names,
field types, and positional constructor.
"""
@generated function _parse_struct_value!(cursor::Cursor, ::Type{T}) where {T}
    return _object_decoder_expr(T, false, (T,))
end

"""
    _fallback_decoder_expr(T)

Classify a target not handled by a primitive method and emit either sentinel
union handling, concrete-struct decoding, or a deterministic unsupported-type
error. Classification runs during specialization, never at parser runtime.
"""
function _fallback_decoder_expr(T)
    if T isa Union
        decoder = _union_decoder_expr(T)
        return :(return $decoder)
    elseif T isa DataType && T <: AbstractVector
        decoder = _converted_vector_decoder_expr(T)
        return :(return $decoder)
    end

    unsupported =
        T isa UnionAll ||
        !(T isa DataType) ||
        !isconcretetype(T) ||
        T <: Number ||
        T <: AbstractString ||
        T <: AbstractArray ||
        T <: AbstractDict ||
        T <: Tuple ||
        T <: Enum ||
        isprimitivetype(T)
    (unsupported || !isstructtype(T)) && return :(_fail(cursor, "unsupported target type"))
    return :(return _parse_struct_value!(cursor, T))
end

"""
    _parse_fallback_value!(cursor, T)

Execute the target-specific fallback emitted by `_fallback_decoder_expr`.
"""
@generated function _parse_fallback_value!(cursor::Cursor, ::Type{T}) where {T}
    return _fallback_decoder_expr(T)
end

function _parse_typed_value!(cursor::Cursor, ::Type{T}) where {T}
    return _parse_fallback_value!(cursor, T)
end

"""
    parse(json)
    parse(json, T)

Parse the JSON text in `json`. Without a target type, return a `JSONValue`.
With a supported target type `T`, decode directly and return a value of `T`.
The input is always interpreted as JSON text, never as a filesystem path.
"""
parse(json::AbstractString) = parse(json, JSONValue)

function parse(json::AbstractString, ::Type{T}) where {T}
    cursor = Cursor(String(json))
    _validate_target!(cursor, T)
    value = _parse_typed_value!(cursor, T)
    _skip_whitespace!(cursor)
    _at_end(cursor) || _fail(cursor, "unexpected content after the JSON value")
    return value
end
