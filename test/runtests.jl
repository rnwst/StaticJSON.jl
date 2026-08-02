using Test
import StaticJSON
using StaticJSON: JSONValue, ParseError, SerializationError, json, parse, unwrap

@testset "StaticJSON" begin
    @testset "Public API and documentation" begin
        @test Set(names(StaticJSON)) == Set((:JSONValue, :StaticJSON, :unwrap))
        @test StaticJSON.parse !== Base.parse
        @test isempty(Docs.undocumented_names(StaticJSON; private = true))
    end

    include("untyped.jl")
    include("typed.jl")
    include("serializer.jl")
    include("errors.jl")
end
