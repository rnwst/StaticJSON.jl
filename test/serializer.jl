using GeometryBasics: Vec

struct SerializedConfig
    name::String
    position::Vec{3,Float32}
    note::Union{Nothing,String}
    optional::Union{Missing,Int}
end

struct AbstractSerializedField
    value::Real
end

struct MissingFirst
    omitted::Union{Missing,Int}
    retained::Int
end

@testset "Generated serializer selection" begin
    @test StaticJSON._indent_width(nothing) == -1
    @test StaticJSON._serializable_union_expr(Union{Missing,Int}, :value, ()) isa Expr
    @test StaticJSON._serializable_union_expr(Union{Nothing,Int}, :value, ()) isa Expr
    @test StaticJSON._serializable_union_expr(Union{Missing,Nothing}, :value, ()) isa Expr
    @test StaticJSON._serializable_union_expr(Union{Int,String}, :value, ()) isa Expr
    @test StaticJSON._serializable_present_expr(Union{Missing,Nothing}, :value, ()) isa Expr
    @test StaticJSON._serializer_expr(Union{Nothing,Int}, :value) isa Expr
    @test StaticJSON._serializer_expr(Symbol, :value) isa Expr
    @test StaticJSON._serializer_expr(Char, :value) isa Expr
    @test StaticJSON._serializable_type_error(Union{}) isa String
    @test StaticJSON._serializable_type_error(Vector) isa String
end

@testset "JSON serialization primitives" begin
    @test json(nothing) == "null"
    @test json(true) == "true"
    @test json(false) == "false"
    @test json("text") == "\"text\""
    @test json(-0.0) == "-0.0"

    for T in (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
        value = T(7)
        @test json(value) == "7"
    end
    for T in (Float16, Float32, Float64)
        value = T(1.25)
        @test parse(json(value), T) == value
    end

    @test_throws SerializationError json(Float16(Inf))
    @test_throws SerializationError json(Float32(-Inf))
    @test_throws SerializationError json(NaN)
    @test_throws SerializationError json(missing)
    @test_throws SerializationError json(big(1))
    @test_throws SerializationError json(:symbol)
    @test sprint(showerror, SerializationError("example")) ==
          "StaticJSON.SerializationError: example"
end

@testset "JSON string serialization" begin
    escaped = "\"\\/\b\f\n\r\t\x01\x1f"
    @test json(escaped) == "\"\\\"\\\\/\\b\\f\\n\\r\\t\\u0001\\u001f\""
    unicode = "¢ࠀက퟿𐀀\U00040000\U0010ffff"
    @test json(unicode) == "\"$unicode\""
    @test parse(json(unicode), String) == unicode

    invalid_utf8 = [
        UInt8[0x80],
        UInt8[0xc0, 0x80],
        UInt8[0xc2],
        UInt8[0xc2, 0x20],
        UInt8[0xe0, 0x9f, 0x80],
        UInt8[0xe1, 0x80, 0x20],
        UInt8[0xed, 0xa0, 0x80],
        UInt8[0xf0, 0x8f, 0x80, 0x80],
        UInt8[0xf1, 0x80, 0x80, 0x20],
        UInt8[0xf4, 0x90, 0x80, 0x80],
        UInt8[0xf5, 0x80, 0x80, 0x80],
    ]
    for bytes in invalid_utf8
        @test_throws SerializationError json(String(bytes))
    end
end

@testset "JSON collection serialization" begin
    @test json(Int[]) == "[]"
    @test json([1, 2, 3]) == "[1,2,3]"
    @test json((1, "two", true)) == "[1,\"two\",true]"
    @test json(Vec{3,Float32}(1, 2, 3)) == "[1.0,2.0,3.0]"
    @test json(Dict{String,Int}()) == "{}"
    @test json(Dict("value" => 1)) == "{\"value\":1}"

    optional_dict = Dict{String,Union{Missing,Int}}("omitted" => missing, "retained" => 2)
    optional_text = json(optional_dict)
    @test optional_text == "{\"retained\":2}"
    @test json(Dict{String,Missing}("omitted" => missing)) == "{}"

    @test_throws SerializationError json(Union{Int,String}[1, "two"])
    @test_throws SerializationError json(Dict(1 => "value"))
    @test_throws SerializationError json(IdDict("value" => 1))
    @test_throws SerializationError json(reshape([1, 2, 3, 4], 2, 2))
    @test_throws SerializationError json((1, missing))
end

@testset "JSON object serialization" begin
    config = SerializedConfig("example", Vec{3,Float32}(1, 2, 3), nothing, missing)
    text = json(config)
    @test text ==
          "{\"name\":\"example\",\"position\":[1.0,2.0,3.0],\"note\":null}"
    @test isequal(parse(text, SerializedConfig), config)

    target = @NamedTuple{
        name::String,
        omitted::Union{Missing,Int},
        nullable::Union{Nothing,String},
    }
    named = target(("example", missing, nothing))
    @test json(named) == "{\"name\":\"example\",\"nullable\":null}"
    @test typeof(parse(json(named), target)) === target

    @test json(MissingFirst(missing, 2)) == "{\"retained\":2}"
    @test_throws SerializationError json(AbstractSerializedField(1))

    tree = TreeNode(1, [TreeNode(2, TreeNode[])])
    tree_text = json(tree)
    @test tree_text == "{\"value\":1,\"children\":[{\"value\":2,\"children\":[]}]}"
    @test parse(tree_text, TreeNode).children[1].value == 2
end

@testset "JSONValue serialization" begin
    value = parse("{\"array\":[1,true,null],\"text\":\"ok\"}")
    text = json(value)
    @test text == "{\"array\":[1.0,true,null],\"text\":\"ok\"}"
    reparsed = unwrap(parse(text))
    @test unwrap(reparsed["text"]) == "ok"
    @test map(unwrap, unwrap(reparsed["array"])) == Any[1.0, true, nothing]
    @test_throws SerializationError json(JSONValue(Inf))
end

@testset "Pretty JSON serialization" begin
    value = (name = "example", values = [1, 2], nested = (enabled = true,))
    @test json(value; indent = 2) == """
    {
      "name": "example",
      "values": [
        1,
        2
      ],
      "nested": {
        "enabled": true
      }
    }"""
    @test json((values = [1, 2],); indent = 0) == """
    {
    "values": [
    1,
    2
    ]
    }"""
    @test json((empty_array = Int[], empty_object = NamedTuple()); indent = 4) == """
    {
        "empty_array": [],
        "empty_object": {}
    }"""
    @test json(1; indent = UInt8(2)) == "1"
    @test_throws ArgumentError json(1; indent = -1)
    @test_throws ArgumentError json(1; indent = true)
    @test_throws ArgumentError json(1; indent = 1.5)
    @test_throws ArgumentError json(1; indent = typemax(UInt128))
end
