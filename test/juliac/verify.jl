using JuliaC

"""
    verify_trimmed_executable(project_root)

Compile the JuliaC fixture through the library API with safe trimming, link it,
and run the resulting executable. Temporary compiler products are discarded
after verification.
"""
function verify_trimmed_executable(project_root::String)
    source = joinpath(project_root, "test", "juliac", "trim_app.jl")
    mktempdir() do build
        image = JuliaC.ImageRecipe(
            output_type = "--output-exe",
            trim_mode = "safe",
            file = source,
            project = project_root,
            img_path = joinpath(build, "staticjson-image.o.a"),
            quiet = true,
        )
        JuliaC.compile_products(image)

        executable = joinpath(build, "staticjson-trim")
        link = JuliaC.LinkRecipe(image_recipe = image, outname = executable)
        JuliaC.link_products(link)
        run(`$executable`)
    end
    return nothing
end

project_root = normpath(joinpath(@__DIR__, "..", ".."))
verify_trimmed_executable(project_root)
