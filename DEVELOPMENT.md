# StaticJSON.jl Development Overview

## Overall Flow

```text
JSON String
  -> byte cursor
  -> recognize the next JSON token
  -> parse recursively
  -> verify that all input was consumed
  -> return JSONValue or requested type
```

The parser reads the input one UTF-8 byte at a time. Based on the next byte, it
knows which JSON construct to parse:

- `"` starts a string
- `[` starts an array
- `{` starts an object
- `t` or `f` starts a Boolean
- `n` starts `null`
- A digit or `-` starts a number

Strings, escapes, UTF-8, numbers, separators, and whitespace are validated
directly without invoking another JSON library.

## Untyped Parsing

```julia
value = parse(json)
```

Every value is returned as a concrete `JSONValue`:

```julia
struct JSONValue
    value::Union{
        Nothing,
        Bool,
        Float64,
        String,
        Dict{String,JSONValue},
        Vector{JSONValue},
    }
end
```

Arrays and objects recursively contain more `JSONValue` objects.

For example:

```json
{"values": [1, true, null]}
```

becomes conceptually:

```text
JSONValue(
  Dict{String,JSONValue}(
    "values" => JSONValue(
      Vector{JSONValue}(
        JSONValue(1.0),
        JSONValue(true),
        JSONValue(nothing)
      )
    )
  )
)
```

Every nesting level uses the same concrete parser methods and container types.
Runtime nesting does not create new Julia types or require new code to be
compiled.

## Typed Parsing

```julia
config = parse(json, Config{Float32})
```

Here, `Config{Float32}` is known while Julia compiles the application.

StaticJSON examines the target type at compilation time:

- Struct field names
- Struct field types
- Vector element types
- Converted concrete `AbstractVector` element types
- Tuple element types
- `NamedTuple` names and types
- `Missing` and `Nothing` unions

It then generates a decoder specialized for that schema.

For a concrete `AbstractVector` target that is not an ordinary `Vector`, the
generated decoder first builds `Vector{eltype(T)}` and then emits a direct
`convert(T, values)` call. This supports fixed-size representations without
introducing package-specific hooks or runtime method discovery.

For a struct such as:

```julia
struct Config{T}
    name::String
    values::Vector{T}
end
```

the generated parser is conceptually similar to:

```julia
function parse_config(cursor)
    name_seen = false
    values_seen = false

    # Read each runtime JSON key and compare it with known constants.
    if key == "name"
        name = parse_string(cursor)
        name_seen = true
    elseif key == "values"
        values = parse_vector_of_float32(cursor)
        values_seen = true
    else
        throw_unknown_key()
    end

    name_seen || throw_missing_key()
    values_seen || throw_missing_key()

    return Config{Float32}(name, values)
end
```

The actual decoder still accepts object keys in any order and rejects missing,
unknown, or duplicate keys.

## Deep Typed Schemas

Initially, nested schemas repeatedly called the same generic dispatcher:

```text
Config
  -> generic decoder for Vector{Channel}
    -> generic decoder for Channel
      -> generic decoder for Vector{Path}
        -> ...
```

Julia eventually stopped analyzing that repeated pattern as a precaution
against infinite compiler recursion.

StaticJSON now expands acyclic schemas into direct generated parsing code:

```text
Config decoder
  -> embedded array parsing
  -> embedded Channel parsing
  -> embedded nested array parsing
  -> embedded Path parsing
```

For genuinely recursive types, StaticJSON remembers which types it has already
expanded. When it encounters the same type again, it emits an ordinary
recursive method call instead of expanding forever.

## JuliaC Compatibility

JuliaC starts at known entrypoints and follows every reachable function call. A
safely trimmed executable cannot fall back to the JIT if a call target was
omitted.

StaticJSON keeps that call graph visible and finite by avoiding:

- `Any` in parsed data
- Runtime field reflection
- Runtime type construction
- `eval`
- `invokelatest`
- Open-ended dynamic dispatch
- Runtime selection among arbitrary union members

Typed schemas are resolved and expanded at compile time. Untyped JSON uses a
closed set of six payload variants and a fixed recursive parser.

Runtime-sized allocation is still allowed. Strings, vectors, and dictionaries
can have arbitrary lengths; their element and value types are simply known in
advance.

The key distinction is:

```text
Runtime data decisions: allowed
Runtime method discovery: avoided
```

The JSON contents can remain completely unknown until runtime. StaticJSON only
ensures that every method needed to process those contents is already visible
to JuliaC when the binary is built.
