# StaticJSON.jl

`StaticJSON.jl` is a strict JSON parser and serializer for applications compiled and safely trimmed with JuliaC. It can decode directly into a statically known Julia type or preserve arbitrary JSON in a closed `JSONValue` tree, without introducing `Any` into the parsed representation.

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Overview](#api-overview)
- [Parsing](#parsing)
- [Serialization](#serialization)
- [Limitations](#limitations)
- [JuliaC Compatibility](#juliac-compatibility)
- [Development](#development)

## Installation

StaticJSON currently requires Julia 1.12 and can be installed directly from its repository:

```julia
import Pkg
Pkg.add(url = "https://github.com/rnwst/StaticJSON.jl")
```

## Quick Start

Import `parse` explicitly because it is separate from `Base.parse`:
```julia
using StaticJSON: JSONValue, json, parse, unwrap

Target = @NamedTuple{host::String, port::Int}
config = parse("""{"port":8080,"host":"localhost"}""", Target)

json(config)  # {"host":"localhost","port":8080}
```

Omit the target type to retain an arbitrary document as `JSONValue`:
```julia
document = parse("""{"host":"localhost","port":8080}""")
object = unwrap(document)      # Dict{String,JSONValue}
host = unwrap(object["host"])  # "localhost"
```

The first argument to `parse` is always JSON text, never a path. Read files explicitly:
```julia
document = parse(read("config.json", String))
```

## API Overview

| Call                          | Result                                             |
|-------------------------------|----------------------------------------------------|
| `parse(text)`                 | Parse arbitrary JSON as `JSONValue`                |
| `parse(text, T)`              | Decode directly into the supported target type `T` |
| `json(value; indent=nothing)` | Serialize a supported value to `String`            |
| `unwrap(value)`               | Remove one `JSONValue` wrapper layer               |

The package exports `JSONValue`, `json`, `parse`, and `unwrap`.


## Parsing

### Typed Parsing

Pass a target type as the second argument to decode directly into that type:

```julia
struct Server
    host::String
    port::Int
    aliases::Vector{String}
    note::Union{Nothing,String}
    retries::Union{Missing,Int}
end

server = parse("""
{
  "port": 443,
  "aliases": ["api"],
  "note": null,
  "host": "example.test"
}
""", Server)
```

The typed parser does not construct an intermediate `JSONValue` tree.

| Target                                 | Required JSON representation                |
|----------------------------------------|---------------------------------------------|
| `JSONValue`                            | Any JSON value                              |
| `Nothing`                              | `null`                                      |
| `Bool`                                 | Boolean                                     |
| `String`                               | String                                      |
| Fixed-width signed or unsigned integer | Exactly integral number                     |
| `Float16`, `Float32`, `Float64`        | Number                                      |
| `Vector{T}`                            | Arbitrary-length array                      |
| Concrete `AbstractVector{T}`           | Array parsed as `Vector{T}`, then converted |
| Fixed `Tuple` or `NTuple`              | Array with the declared length              |
| `Dict{String,T}`                       | Object with values decoded as `T`           |
| Concrete `NamedTuple`                  | Object matching its names and types         |
| Concrete struct                        | Object matching its fields and field types  |

Supported integer targets are `Int8` through `Int128`, `UInt8` through
`UInt128`, `Int`, and `UInt`.

### Object Fields, Missing, and Null

Struct and `NamedTuple` keys can appear in any order. Names must exactly match Julia field names. Unknown keys, duplicate keys, and missing required keys throw `StaticJSON.ParseError`.

Structs are constructed through their positional constructor in field order:
```julia
Target(field1, field2, ...)
```

Keyword defaults are not consulted. A custom inner constructor may validate the completed values, but it must provide the matching positional constructor.

`Nothing` represents an explicit JSON `null`; `Missing` represents an absent object field:

| Field type                 | Key absent | Explicit `null` | Ordinary value |
|----------------------------|------------|-----------------|----------------|
| `Union{Nothing,T}`         | Error      | `nothing`       | Decoded as `T` |
| `Union{Missing,T}`         | `missing`  | Error           | Decoded as `T` |
| `Union{Missing,Nothing,T}` | `missing`  | `nothing`       | Decoded as `T` |

`Missing` is not a JSON token and cannot be produced for an array element or a top-level value.

### Collections

Concrete `AbstractVector` targets use Julia's standard conversion protocol. StaticJSON parses an array as `Vector{eltype(T)}` and calls `convert(T, values)`. This supports fixed-size representations such as GeometryBasics vectors without introducing a package dependency:

```julia
using GeometryBasics: Vec

position = parse("[1, 2, 3]", Vec{3,Float32})
```

The conversion also works in nested fields. Conversion errors, including fixed-length mismatches, propagate unchanged. The target must be concrete and its element schema must be statically known and supported.

Fixed tuples represent fixed-shape arrays:
```julia
parse("[1, \"ready\"]", Tuple{Int,String})
parse("[1, 2, 3]", NTuple{3,Int})
```

An unbounded `Tuple{Vararg{T}}` is unsupported because each runtime length would produce a different concrete type. Use `Vector{T}` instead.

### Number Conversion

Untyped numbers become `Float64`. Typed floating-point values use normal IEEE rounding and reject overflow to infinity.

Integer targets are converted directly from the decimal token without first using `Float64`. Fractions and exponents are accepted only when their mathematical value is exactly integral:
```julia
parse("1.0", Int)    # 1
parse("100e-2", Int) # 1
parse("1e3", Int)    # 1000
parse("1.1", Int)    # throws StaticJSON.ParseError
```

Signed, unsigned, and width-specific overflow is checked.

### Untyped Parsing with JSONValue

`parse(text)` returns a `JSONValue` whose payload follows this mapping:

| JSON    | `JSONValue` payload      |
|---------|--------------------------|
| `null`  | `nothing`                |
| Boolean | `Bool`                   |
| Number  | `Float64`                |
| String  | `String`                 |
| Array   | `Vector{JSONValue}`      |
| Object  | `Dict{String,JSONValue}` |

```julia
document = parse("""
{
  "name": "example",
  "ports": [80, 443],
  "enabled": true
}
""")

object = unwrap(document)        # Dict{String,JSONValue}
ports = unwrap(object["ports"])  # Vector{JSONValue}
first_port = unwrap(ports[1])    # 80.0
```

`unwrap` removes exactly one wrapper layer; nested array and object values remain wrapped. This closed recursive representation avoids `Vector{Any}` and `Dict{String,Any}` while retaining a consistent return type. See [`DEVELOPMENT.md`](DEVELOPMENT.md#untyped-parsing) for the type design.

### Input, Compliance, and Parse Errors

The parser accepts any RFC 8259 value at the document root and enforces its number, string, escape, and whitespace grammar. It rejects comments, trailing commas, malformed UTF-8, invalid UTF-16 surrogate escapes, duplicate decoded object keys, and content following the root value.

Malformed JSON and parser-detected target mismatches throw the unexported `StaticJSON.ParseError`, which reports a one-based byte offset into the input.

## Serialization

`json(value)` serializes a supported Julia value to compact JSON:
```julia
text = json((name = "example", values = [1, 2], enabled = true))
# {"name":"example","values":[1,2],"enabled":true}
```

### Supported Values

| Julia value                                      | JSON representation                  |
|--------------------------------------------------|--------------------------------------|
| `nothing`                                        | `null`                               |
| `Bool`                                           | Boolean                              |
| Fixed-width integer or finite IEEE float         | Number                               |
| `String`                                         | String                               |
| `Vector`, concrete `AbstractVector`, fixed tuple | Array                                |
| `Dict{String,T}`                                 | Object in dictionary iteration order |
| Concrete struct or `NamedTuple`                  | Object in field declaration order    |
| `JSONValue`                                      | Its recursively wrapped JSON value   |

### Missing and Null

Object members whose value is `missing` are omitted. `nothing` is serialized as an explicit `null`:
```julia
value = (
    required = 1,
    optional = missing,
    nullable = nothing,
)

json(value) # {"required":1,"nullable":null}
```

A top-level `missing` or `missing` inside an array or tuple is an error because JSON has no corresponding value.

### Pretty Printing

Pass a nonnegative integer as `indent` to add structural line breaks and that many spaces per nesting level:

```julia
json((name = "example", values = [1, 2]); indent = 2)
```

```json
{
  "name": "example",
  "values": [
    1,
    2
  ]
}
```

The default `indent=nothing` produces compact output. `indent=0` uses line breaks without leading spaces. Empty arrays and objects remain `[]` and `{}`.

### Serialization Errors

Unsupported values throw the unexported `StaticJSON.SerializationError`. Serialization rejects non-finite floats, invalid UTF-8, and unsupported static schemas. Errors raised while accessing a custom vector representation propagate unchanged.

## Limitations

General unions such as `Union{Int,String}` are unsupported because alternatives can overlap and require precedence, backtracking, or discriminator rules. Only the `Missing` and `Nothing` sentinel unions described above are accepted.

StaticJSON also excludes `BigInt`, `BigFloat`, multidimensional arrays, abstract schema fields, abstract collection targets, non-string dictionary keys, field-name remapping, keyword defaults, and custom decoding hooks. Parse special representations into `String`, a supported primitive, or `JSONValue`, then apply application-specific conversion separately.

Serialization input must be acyclic. Recursive types are supported when their runtime values terminate.

## JuliaC Compatibility

The runtime parser and serializer avoid `Any`, `eval`, `invokelatest`, runtime type construction, and runtime field reflection. Generated methods embed concrete struct, tuple, collection, and sentinel-union schemas into a finite, compiler-visible call graph.

Every typed target used by a trimmed binary must be statically reachable from an entrypoint. Runtime JSON contents and collection sizes remain arbitrary; only the requested Julia schema is fixed.

See [`DEVELOPMENT.md`](DEVELOPMENT.md#juliac-compatibility) for the compiler design and [`test/juliac/trim_app.jl`](test/juliac/trim_app.jl) for an end-to-end trimmed application.

## Development

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for the implementation overview, test and coverage commands, and JuliaC integration-test setup.
