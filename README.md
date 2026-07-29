# StaticJSON.jl

`StaticJSON.jl` is a strict JSON parser designed for applications compiled and
trimmed with JuliaC. It can either preserve an arbitrary JSON document in a
closed `JSONValue` tree or decode directly into a statically known Julia type.

The package exports `JSONValue`, `parse`, and `unwrap`. Its `parse` function is
separate from `Base.parse`, so explicit imports avoid Julia's name conflict:

```julia
using StaticJSON: JSONValue, parse, unwrap
```

The first argument is always JSON text. It is never interpreted as a path. To
parse a file, read it explicitly:

```julia
document = parse(read("config.json", String))
```

## Untyped JSON

`parse(json)` always returns a `JSONValue`:

```julia
document = parse("""
{
  "name": "example",
  "ports": [80, 443],
  "enabled": true
}
""")

object = unwrap(document)        # Dict{String,JSONValue}
name = unwrap(object["name"])    # "example"
ports = unwrap(object["ports"])  # Vector{JSONValue}
first_port = unwrap(ports[1])    # 80.0
```

`unwrap` removes exactly one wrapper layer. It deliberately does not
recursively create `Dict{String,Any}` or `Vector{Any}`.

The untyped mapping is:

| JSON | `JSONValue` payload |
|---|---|
| `null` | `nothing` |
| Boolean | `Bool` |
| Number | `Float64` |
| String | `String` |
| Array | `Vector{JSONValue}` |
| Object | `Dict{String,JSONValue}` |

### Why `JSONValue` exists

JSON arrays and objects can recursively contain values of different kinds. A
conventional Julia representation therefore uses `Vector{Any}` and
`Dict{String,Any}`. Those containers erase the finite set of possible value
types and encourage dynamic dispatch in code consuming the result.

Julia also does not permit a directly recursive union alias such as:

```julia
# Not valid Julia:
const JSON = Union{Nothing,Bool,Float64,String,Vector{JSON},Dict{String,JSON}}
```

`JSONValue` closes that recursion through one nominal concrete type:

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

The wrapper provides a consistent return type, concrete recursive containers,
and a finite compiler-visible payload union. Consumers in a trimmed program can
use explicit `isa` branches for the six payload variants without unresolved
dynamic dispatch.

## Typed Parsing

Pass a target type as the second argument to decode directly into that type:

```julia
struct Server{T}
    host::String
    port::T
    aliases::Vector{String}
    note::Union{Nothing,String}
    retries::Union{Missing,Int}
end

server = parse("""
{
  "port": 443.0,
  "aliases": ["api"],
  "note": null,
  "host": "example.test"
}
""", Server{Int})
```

The typed parser decodes directly. It does not construct an intermediate
`JSONValue` tree.

Supported targets are:

| Target | JSON representation |
|---|---|
| `JSONValue` | Any JSON value |
| `Nothing` | `null` |
| `Bool` | Boolean |
| `String` | String |
| Fixed-width signed or unsigned integer | Exactly integral number |
| `Float16`, `Float32`, `Float64` | Number |
| `Vector{T}` | Arbitrary-length array |
| Concrete `AbstractVector{T}` | Array parsed as `Vector{T}`, then converted |
| Fixed `Tuple` or `NTuple` | Array with exactly the declared length |
| `Dict{String,T}` | Object with values decoded as `T` |
| Concrete `NamedTuple` | Object matching its names and types |
| Concrete struct | Object matching its fields and field types |

`Int8` through `Int128`, `UInt8` through `UInt128`, `Int`, and `UInt` are
supported. `BigInt` and `BigFloat` are intentionally excluded.

### Converted Vector Types

Concrete `AbstractVector` targets are supported through Julia's standard
`convert` protocol. StaticJSON first parses the JSON array as
`Vector{eltype(T)}` and then calls `convert(T, values)`:

```julia
using GeometryBasics: Vec

position = parse("[1, 2, 3]", Vec{3,Float32})
```

This also works for nested fields:

```julia
struct Point
    position::Vec{3,Float32}
end

point = parse("{\"position\":[1,2,3]}", Point)
```

StaticJSON does not depend on GeometryBasics. Both the target and its element
type are known during compilation, so the conversion call remains statically
resolvable. The third-party `convert` method must itself be JuliaC-compatible.
Conversion errors, including fixed-length mismatches, are propagated unchanged.
Abstract vector targets and multidimensional arrays remain unsupported.

### Exact Object Matching

Struct and `NamedTuple` keys can appear in any order. Unknown keys, duplicate
keys, and missing required keys throw `StaticJSON.ParseError`. JSON names must
exactly equal Julia field names; there is no name-remapping mechanism.

Structs are constructed through their positional constructor in field order:

```julia
Target(field1, field2, ...)
```

Keyword defaults are not consulted. A custom inner constructor may validate
the completed values, but it must provide the matching positional constructor.

### Nullable And Optional Fields

`Nothing` represents an explicit JSON `null`. `Missing` represents an absent
object field:

| Field type | Key absent | Explicit `null` | Ordinary value |
|---|---|---|---|
| `Union{Nothing,T}` | Error | `nothing` | Decoded as `T` |
| `Union{Missing,T}` | `missing` | Error | Decoded as `T` |
| `Union{Missing,Nothing,T}` | `missing` | `nothing` | Decoded as `T` |

`Missing` is not a JSON token and cannot be produced for an array element or a
top-level value.

### Number Conversion

Untyped numbers become `Float64`. Typed floating-point values use normal IEEE
rounding and reject overflow to infinity.

Integer targets are converted directly from the decimal token without first
using `Float64`. Decimal fractions and exponents are accepted when the
mathematical value is exactly integral:

```julia
parse("1.0", Int)    # 1
parse("100e-2", Int) # 1
parse("1e3", Int)    # 1000
parse("1.1", Int)    # throws ParseError
```

Signed, unsigned, and width-specific overflow is checked.

### Tuples And Named Tuples

Fixed tuples represent fixed-shape JSON arrays:

```julia
parse("[1, \"ready\"]", Tuple{Int,String})
parse("[1, 2, 3]", NTuple{3,Int})
```

An unbounded `Tuple{Vararg{T}}` is unsupported because every runtime array
length would produce a different concrete tuple type. Use `Vector{T}` instead.

A `NamedTuple` is a statically typed object target:

```julia
Target = @NamedTuple{host::String, port::Int}
parse("{\"port\":8080,\"host\":\"localhost\"}", Target)
```

## Deliberate Exclusions

General unions such as `Union{Int,String}` are unsupported because alternatives
can overlap and require precedence, backtracking, or discriminator rules.
Only the `Missing` and `Nothing` sentinel unions described above are accepted.

The package also excludes field-name remapping, defaults other than `missing`,
and custom decoding hooks. Parse special representations into `String`, a
primitive target, or `JSONValue`, then perform application-specific conversion
separately.

## JSON Compliance

The parser accepts any RFC 8259 value at the document root and enforces its
number, string, escape, and whitespace grammar. It rejects comments, trailing
commas, malformed UTF-8, invalid UTF-16 surrogate escapes, duplicate decoded
object keys, and content following the root value.

Errors are reported as `StaticJSON.ParseError` with a one-based byte offset.
The error type remains unexported but can be named with its module qualifier.

## JuliaC Trimming

The runtime parser does not use `Any`, `eval`, `invokelatest`, runtime type
construction, or runtime field reflection. Struct, tuple, and `NamedTuple`
decoders are generated for concrete target types, leaving direct field parsing
and constructor calls in compiled code.

Generated decoders embed acyclic composite schemas transitively. This avoids
Julia's recursive inference limiter dropping deeply nested vector/struct edges
during safe trimming. A compile-time `seen` stack terminates genuine recursive
struct schemas with an ordinary recursive method call.

As with all JuliaC applications, every typed target used by a trimmed binary
must be statically reachable from an entrypoint. Runtime JSON contents remain
arbitrary; only the requested Julia schema is fixed.

The integration test uses JuliaC's library API rather than its command-line
wrapper:

```julia
image = JuliaC.ImageRecipe(
    output_type = "--output-exe",
    trim_mode = "safe",
    file = "app.jl",
    project = pwd(),
    img_path = "image.o.a",
)
JuliaC.compile_products(image)

link = JuliaC.LinkRecipe(image_recipe = image, outname = "app")
JuliaC.link_products(link)
```

Run the package tests and trimming verification with:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
julia --project=test test/juliac/verify.jl
```

## Coverage

Run source coverage through the project-local `Coverage` dependency:

```sh
julia --project=test -e 'using Coverage; clean_folder(".")'
julia --project=. -e 'using Pkg; Pkg.test(coverage=true)'
julia --project=test test/coverage.jl
```

The test suite is maintained at 100% executable source-line coverage.
