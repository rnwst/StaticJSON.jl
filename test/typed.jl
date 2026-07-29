struct Service{T}
    host::String
    port::T
    aliases::Vector{String}
    note::Union{Nothing,String}
    retries::Union{Missing,Int}
end

struct EmptyRecord end

mutable struct MutableRecord
    value::Int
end

struct NoPositionalConstructor
    value::Int
    NoPositionalConstructor() = new(0)
end

struct WrongConstructor
    value::Int
    WrongConstructor(value::Int) = value
end

struct TreeNode
    value::Int
    children::Vector{TreeNode}
end

struct RawField
    value::JSONValue
end

@enum TestChoice first_choice second_choice

@testset "Generated decoder selection" begin
    named_target = @NamedTuple{value::Int}
    @test StaticJSON._direct_decoder_expr(Dict{String,Int}) isa Expr
    @test StaticJSON._direct_decoder_expr(Tuple{Int,String}) isa Expr
    @test StaticJSON._direct_decoder_expr(named_target) isa Expr
    @test StaticJSON._direct_decoder_expr(named_target, (named_target,)) isa Expr
    @test StaticJSON._direct_decoder_expr(Service{Int}) isa Expr
end

@testset "Typed primitives and numbers" begin
    @test parse("null", Nothing) === nothing
    @test parse("true", Bool) === true
    @test parse("false", Bool) === false
    @test parse("\"hello\"", String) == "hello"
    @test parse("1.5", Float16) === Float16(1.5)
    @test parse("1.25", Float32) === Float32(1.25)
    @test parse("1.125", Float64) === 1.125
    @test signbit(parse("-0", Float64))

    signed_types = (Int8, Int16, Int32, Int64, Int128)
    unsigned_types = (UInt8, UInt16, UInt32, UInt64, UInt128)
    for T in signed_types
        @test parse(string(typemin(T)), T) === typemin(T)
        @test parse(string(typemax(T)), T) === typemax(T)
        @test_throws ParseError parse(string(typemax(T), "0"), T)
    end
    for T in unsigned_types
        @test parse(string(typemax(T)), T) === typemax(T)
        @test parse("-0", T) === zero(T)
        @test_throws ParseError parse("-1", T)
        @test_throws ParseError parse(string(typemax(T), "0"), T)
    end

    @test parse("1.0", Int) == 1
    @test parse("-1", Int) == -1
    @test parse("100e-2", Int) == 1
    @test parse("0.001e3", Int) == 1
    @test parse("1e3", Int) == 1000
    @test parse("0e99999", Int) == 0
    @test_throws ParseError parse("1.1", Int)
    @test_throws ParseError parse("1e-10000", Int)
    @test_throws ParseError parse("1e10000", Int128)
    @test_throws ParseError parse("1e400", Float64)
    @test_throws ParseError parse("null", Float32)
    @test_throws ParseError parse("true", Int)
    @test_throws ParseError parse("1", Bool)
end

@testset "Typed collections" begin
    @test parse("[]", Vector{Int}) == Int[]
    @test parse("[1,2.0,3e0]", Vector{Int}) == [1, 2, 3]
    @test parse("[[1],[2,3]]", Vector{Vector{Int}}) == [[1], [2, 3]]
    @test_throws ParseError parse("{}", Vector{Int})

    @test parse("{}", Dict{String,Int}) == Dict{String,Int}()
    @test parse("{\"a\":1,\"b\":2.0}", Dict{String,Int}) == Dict("a" => 1, "b" => 2)
    @test_throws ParseError parse("[]", Dict{String,Int})
    @test_throws ParseError parse("{\"a\":1,\"a\":2}", Dict{String,Int})
    @test_throws ParseError parse("{1:2}", Dict{String,Int})

    @test parse("[]", Tuple{}) == ()
    @test parse("[1]", Tuple{Int}) == (1,)
    @test parse("[1,\"x\",true]", Tuple{Int,String,Bool}) == (1, "x", true)
    @test parse("[1,2,3]", NTuple{3,Int}) == (1, 2, 3)
    @test parse("[null]", Tuple{Union{Nothing,Int}}) == (nothing,)
    @test_throws ParseError parse("[]", Tuple{Int})
    @test_throws ParseError parse("[1,2]", Tuple{Int})
    @test_throws ParseError parse("[1 2]", Tuple{Int,Int})
    @test_throws ParseError parse("[1]", Tuple{Int,Int})
    @test_throws ParseError parse("[1]", Tuple{Vararg{Int}})
end

@testset "NamedTuple and struct targets" begin
    target = @NamedTuple{
        host::String,
        port::Int,
        note::Union{Nothing,String},
        optional::Union{Missing,Int},
    }
    value = parse("{\"port\":8080.0,\"host\":\"localhost\",\"note\":null}", target)
    @test typeof(value) === target
    @test isequal(value, (host = "localhost", port = 8080, note = nothing, optional = missing))
    @test parse("{}", NamedTuple{(),Tuple{}}) == NamedTuple()
    @test_throws ParseError parse("{\"host\":\"x\",\"port\":1,\"note\":null,\"extra\":2}", target)
    @test_throws ParseError parse("{\"host\":\"x\",\"note\":null}", target)
    @test_throws ParseError parse("{\"host\":\"x\",\"port\":1,\"note\":null,\"port\":2}", target)
    @test_throws ParseError parse("{host:\"x\"}", target)

    service = parse(
        "{\"aliases\":[\"api\"],\"port\":443.0,\"note\":null,\"host\":\"example.test\"}",
        Service{Int},
    )
    @test @inferred(parse(
        "{\"aliases\":[],\"port\":80,\"note\":null,\"host\":\"inferred\"}",
        Service{Int},
    )) isa Service{Int}
    @test service.host == "example.test"
    @test service.port == 443
    @test service.aliases == ["api"]
    @test service.note === nothing
    @test service.retries === missing
    @test parse("{}", EmptyRecord) isa EmptyRecord
    @test_throws ParseError parse("{\"unexpected\":1}", EmptyRecord)
    @test parse("{\"value\":2}", MutableRecord).value == 2
    @test parse("{\"value\":1,\"children\":[{\"value\":2,\"children\":[]}]}", TreeNode).children[1].value == 2
    @test unwrap(parse("{\"value\":{\"custom\":true}}", RawField).value) isa
          Dict{String,JSONValue}
    @test_throws ParseError parse("{\"host\":\"x\",\"port\":1,\"aliases\":[],\"note\":null,\"extra\":2}", Service{Int})
    @test_throws ParseError parse("{\"host\":\"x\",\"port\":1,\"aliases\":[]}", Service{Int})
    @test_throws ParseError parse("{\"host\":\"x\",\"port\":1,\"aliases\":[],\"note\":null,\"port\":2}", Service{Int})
    @test_throws MethodError parse("{\"value\":1}", NoPositionalConstructor)
    @test_throws ParseError parse("{\"value\":1}", WrongConstructor)
end

@testset "Sentinel unions and unsupported targets" begin
    @test parse("null", Union{Nothing,Int}) === nothing
    @test parse("1", Union{Nothing,Int}) == 1
    @test parse("1", Union{Missing,Int}) == 1
    @test parse("null", Union{Missing,Nothing,Int}) === nothing
    @test parse("null", Union{Missing,Nothing}) === nothing
    @test_throws ParseError parse("null", Union{Missing,Int})
    @test_throws ParseError parse("1", Union{Missing,Nothing})
    @test_throws ParseError parse("1", Missing)
    @test_throws ParseError parse("1", Union{Int,String})
    @test_throws ParseError parse("1", Union{Int8,Int16})
    @test_throws ParseError parse("1", Union{Float32,Float64})
    @test_throws ParseError parse("1", Union{})
    @test_throws ParseError parse("[]", Vector{Union{Int,String}})
    @test_throws ParseError parse("{}", @NamedTuple{value::Union{Missing,Int,String}})
    @test_throws ParseError parse("1", Any)
    @test_throws ParseError parse("1", Real)
    @test_throws ParseError parse("1", BigInt)
    @test_throws ParseError parse("1", BigFloat)
    @test_throws ParseError parse("\"x\"", Symbol)
    @test_throws ParseError parse("1", TestChoice)
    @test_throws ParseError parse("{}", Dict{Symbol,Int})
    @test_throws ParseError parse("{}", IdDict{String,Int})
    @test_throws ParseError parse("[]", Matrix{Int})
    @test_throws ParseError parse("[]", Vector)
end
