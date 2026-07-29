using Test
import StaticJSON
using StaticJSON: JSONValue, ParseError, parse, unwrap

@testset "Public API and documentation" begin
    @test Set(names(StaticJSON)) == Set((:JSONValue, :StaticJSON, :parse, :unwrap))
    @test StaticJSON.parse !== Base.parse
    @test isempty(Docs.undocumented_names(StaticJSON; private = true))
end

include("untyped.jl")
include("typed.jl")
include("errors.jl")
