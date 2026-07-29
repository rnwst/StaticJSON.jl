@testset "Error reporting and complete consumption" begin
    error = try
        parse("true false")
        nothing
    catch caught
        caught
    end
    @test error isa ParseError
    @test error.position == 6
    @test sprint(showerror, error) ==
          "StaticJSON.ParseError at byte 6: unexpected content after the JSON value"

    @test_throws ParseError parse("[true false]")
    @test_throws ParseError parse("{\"a\":true false}")
    @test_throws ParseError parse("\"\\")
    @test_throws ParseError parse("\"\\u")
end
