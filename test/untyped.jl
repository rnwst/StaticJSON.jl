@testset "JSONValue and untyped parsing" begin
    @test isconcretetype(JSONValue)
    @test @inferred(parse("null")) isa JSONValue
    @test unwrap(JSONValue(nothing)) === nothing
    @test unwrap(parse("null")) === nothing
    @test unwrap(parse("true")) === true
    @test unwrap(parse("false")) === false
    @test unwrap(parse("  -12.5e+2\r\n")) === -1250.0
    @test unwrap(parse(SubString("x\"text\"y", 2, 7))) == "text"

    array = unwrap(parse("[null, true, 1, \"x\", [], {}]"))
    @test array isa Vector{JSONValue}
    @test map(unwrap, array[1:4]) == Any[nothing, true, 1.0, "x"]
    @test isempty(unwrap(array[5]))
    @test isempty(unwrap(array[6]))

    object = unwrap(parse("{\"array\":[1,2],\"object\":{\"ok\":true}}"))
    @test object isa Dict{String,JSONValue}
    @test map(unwrap, unwrap(object["array"])) == [1.0, 2.0]
    @test unwrap(unwrap(object["object"])["ok"]) === true

    @test unwrap(parse("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"")) == "\"\\/\b\f\n\r\t"
    @test unwrap(parse("\"\\u0041\\u00a2\\u20ac\\ud800\\udc00\"")) == "A¢€𐀀"
    @test unwrap(parse("\"¢ࠀက퟿𐀀\U00040000\U0010ffff\"")) == "¢ࠀက퟿𐀀\U00040000\U0010ffff"

    duplicate = try
        parse("{\"a\":1,\"\\u0061\":2}")
        nothing
    catch error
        error
    end
    @test duplicate isa ParseError
    @test occursin("duplicate object key", sprint(showerror, duplicate))
end

@testset "Malformed JSON strings and UTF-8" begin
    invalid_json = [
        "",
        " ",
        "nil",
        "tru",
        "false!",
        "[1 2]",
        "[1,]",
        "{\"a\" 1}",
        "{a:1}",
        "{\"a\":1,}",
        "\"unterminated",
        "\"line\nfeed\"",
        "\"\\x\"",
        "\"\\u12x4\"",
        "\"\\ud800x\"",
        "\"\\ud800\\x000\"",
        "\"\\ud800\\u0041\"",
        "\"\\udc00\"",
        "01",
        "-",
        "1.",
        "1e",
        "1e+",
        "--1",
        "[",
        "{",
    ]
    for text in invalid_json
        @test_throws ParseError parse(text)
    end

    invalid_utf8 = [
        UInt8[0x22, 0x80, 0x22],
        UInt8[0x22, 0xc0, 0x80, 0x22],
        UInt8[0x22, 0xc2],
        UInt8[0x22, 0xc2, 0x20, 0x22],
        UInt8[0x22, 0xe0, 0x9f, 0x80, 0x22],
        UInt8[0x22, 0xe1, 0x80, 0x20, 0x22],
        UInt8[0x22, 0xed, 0xa0, 0x80, 0x22],
        UInt8[0x22, 0xf0, 0x8f, 0x80, 0x80, 0x22],
        UInt8[0x22, 0xf1, 0x80, 0x80, 0x20, 0x22],
        UInt8[0x22, 0xf4, 0x90, 0x80, 0x80, 0x22],
        UInt8[0x22, 0xf5, 0x80, 0x80, 0x80, 0x22],
    ]
    for bytes in invalid_utf8
        @test_throws ParseError parse(String(bytes))
    end
end
