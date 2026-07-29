using StaticJSON: JSONValue, ParseError, parse, unwrap

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

struct TrimPoint{T}
    label::String
    position::Vector{T}
    direction::Vector{T}
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

    rejected = false
    try
        parse("{\"name\":\"incomplete\"}", TrimConfig{Float32})
    catch error
        error isa ParseError || return Cint(12)
        rejected = true
    end
    rejected || return Cint(13)
    return Cint(0)
end
