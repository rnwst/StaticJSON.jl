"""
`StaticJSON` parses and serializes JSON through closed representations and
statically generated schemas, allowing JuliaC to trim all unreachable code.
"""
module StaticJSON

export JSONValue, json, parse, unwrap

include("parser.jl")
include("typed.jl")
include("serializer.jl")

end
