"""
`StaticJSON` parses JSON through a closed value representation or directly into
statically known Julia types, allowing JuliaC to trim all unreachable code.
"""
module StaticJSON

export JSONValue, parse, unwrap

include("parser.jl")
include("typed.jl")

end
