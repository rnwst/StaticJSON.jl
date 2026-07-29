using StaticJSON: JSONValue, ParseError, SerializationError, json, parse, unwrap

struct TrimConfig{T}
    name::String
    threshold::T
    labels::Vector{String}
    note::Union{Nothing,String}
    retries::Union{Missing,Int}
end

struct TrimChannel{T}
    gain::T
end

struct NestedTrimConfig{T}
    channels::Vector{TrimChannel{T}}
end

struct TrimTable{T}
    id::String
    inputs::Vector{T}
    outputs::Vector{T}
    scale::T
    offset::T
end

struct TrimVec{N,T} <: AbstractVector{T}
    data::NTuple{N,T}
end

"""Return the statically known dimensions of a `TrimVec`."""
Base.size(::TrimVec{N}) where {N} = (N,)

"""Return one element from a `TrimVec`."""
Base.getindex(vector::TrimVec, index::Int) = vector.data[index]

"""Convert a runtime-sized vector into a length-checked `TrimVec`."""
function Base.convert(::Type{TrimVec{N,T}}, values::Vector{T}) where {N,T}
    length(values) == N || throw(DimensionMismatch("expected $N elements"))
    return TrimVec{N,T}(ntuple(index -> values[index], Val(N)))
end

struct TrimPoint{T}
    label::String
    position::TrimVec{3,T}
    direction::TrimVec{3,T}
end

struct TrimPath{T}
    points::Vector{TrimPoint{T}}
end

struct TrimGroup{T}
    name::String
    paths::Vector{TrimPath{T}}
end

struct DeepTrimConfig{T}
    tables::Vector{TrimTable{T}}
    groups::Vector{TrimGroup{T}}
end

"""
    parse_deep_config(json)

Parse a runtime string into a multi-branch schema with several nested
vector/struct levels. This is the regression entrypoint for transitive decoder
reachability under safe trimming.
"""
parse_deep_config(json::String)::DeepTrimConfig{Float32} =
    parse(json, DeepTrimConfig{Float32})

Base.Experimental.entrypoint(parse_deep_config, (String,))

"""
    normalize_deep_config(json_text, indentation)

Parse and reserialize a runtime deep schema, then parse the generated JSON back
to its concrete type. This retains compact and pretty serializer paths.
"""
function normalize_deep_config(json_text::String, indentation::Int)::DeepTrimConfig{Float32}
    value = parse_deep_config(json_text)
    encoded = json(value; indent = indentation)
    return parse(encoded, DeepTrimConfig{Float32})
end

Base.Experimental.entrypoint(normalize_deep_config, (String, Int))

struct RecursiveTrimNode
    value::Int
    children::Vector{RecursiveTrimNode}
    next::Union{Nothing,RecursiveTrimNode}
end

"""
    parse_recursive_node(json)

Retain a genuinely recursive schema as a runtime-string trim entrypoint. The
generated decoder must terminate its compile-time expansion at the recursive
edge while preserving the runtime call.
"""
parse_recursive_node(json::String)::RecursiveTrimNode =
    parse(json, RecursiveTrimNode)

Base.Experimental.entrypoint(parse_recursive_node, (String,))

"""
    normalize_recursive_node(json_text)

Exercise generated serialization at a genuine recursive schema edge.
"""
function normalize_recursive_node(json_text::String)::String
    return json(parse_recursive_node(json_text))
end

Base.Experimental.entrypoint(normalize_recursive_node, (String,))

"""
    normalize_untyped(json_text)

Exercise every closed `JSONValue` serialization branch from runtime JSON text.
"""
normalize_untyped(json_text::String)::String = json(parse(json_text))

Base.Experimental.entrypoint(normalize_untyped, (String,))

"""
    json_score(value)

Visit every `JSONValue` payload through explicit finite branches. This keeps
the untyped consumer statically dispatched while exercising recursive objects
and arrays in the trimmed image.
"""
function json_score(value::JSONValue)::Int
    payload = unwrap(value)
    if payload === nothing
        return 1
    elseif payload isa Bool
        return payload ? 2 : 3
    elseif payload isa Float64
        return trunc(Int, payload)
    elseif payload isa String
        return ncodeunits(payload)
    elseif payload isa Vector{JSONValue}
        total = 0
        for item in payload
            total += json_score(item)
        end
        return total
    else
        object = payload::Dict{String,JSONValue}
        total = 0
        for (key, item) in object
            total += ncodeunits(key) + json_score(item)
        end
        return total
    end
end

"""
    main(args)

Exercise untyped and typed parsing from a JuliaC executable. A nonzero result
identifies a failed invariant to the verification harness.
"""
function @main(args)::Cint
    text = isempty(args) ? "{\"items\":[null,true,false,4,\"x\"]}" : args[1]
    json_score(parse(text)) > 0 || return Cint(1)

    config = parse(
        "{\"threshold\":2.0,\"labels\":[\"trimmed\"],\"note\":null,\"name\":\"demo\"}",
        TrimConfig{Float32},
    )
    config.name == "demo" || return Cint(2)
    config.threshold == 2.0f0 || return Cint(3)
    config.note === nothing || return Cint(4)
    config.retries === missing || return Cint(5)

    tuple = parse("[1.0,\"ok\"]", Tuple{Int,String})
    tuple == (1, "ok") || return Cint(6)
    named = parse("{\"enabled\":true}", @NamedTuple{enabled::Bool})
    named.enabled || return Cint(7)
    counts = parse("{\"first\":1.0,\"second\":2}", Dict{String,Int})
    counts["first"] + counts["second"] == 3 || return Cint(8)
    nested = parse("{\"channels\":[{\"gain\":1.5}]}", NestedTrimConfig{Float32})
    nested.channels[1].gain == 1.5f0 || return Cint(9)
    deep_text = if length(args) > 1
        args[2]
    else
        """
        {
          "tables": [
            {"id":"t", "inputs":[1], "outputs":[2], "scale":3, "offset":4}
          ],
          "groups": [
            {
              "name":"g",
              "paths":[
                {"points":[{"label":"p", "position":[5,6,7], "direction":[0,0,1]}]}
              ]
            }
          ]
        }
        """
    end
    deep = parse_deep_config(deep_text)
    deep.tables[1].scale == 3.0f0 || return Cint(10)
    deep.groups[1].paths[1].points[1].position[2] == 6.0f0 || return Cint(11)
    compact_deep = json(deep)
    occursin('\n', compact_deep) && return Cint(12)
    parse(compact_deep, DeepTrimConfig{Float32}).tables[1].offset == 4.0f0 ||
        return Cint(13)
    pretty_deep = json(deep; indent = 2)
    occursin('\n', pretty_deep) || return Cint(14)
    parse(pretty_deep, DeepTrimConfig{Float32}).groups[1].name == "g" ||
        return Cint(15)
    occursin("\"items\"", normalize_untyped(text)) || return Cint(16)

    rejected = false
    try
        parse("{\"name\":\"incomplete\"}", TrimConfig{Float32})
    catch error
        error isa ParseError || return Cint(17)
        rejected = true
    end
    rejected || return Cint(18)
    rejected_float = false
    try
        json(Inf)
    catch error
        error isa SerializationError || return Cint(19)
        rejected_float = true
    end
    rejected_float || return Cint(20)
    return Cint(0)
end
