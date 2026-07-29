using Coverage

"""
    verify_full_coverage(source_directory)

Process Julia coverage files below `source_directory` and fail unless every
executable source line was covered.
"""
function verify_full_coverage(source_directory::String)
    files = Coverage.process_folder(source_directory)
    covered, total = Coverage.get_summary(files)
    total > 0 || error("coverage analysis found no executable source lines")
    covered == total || error("source coverage is $covered/$total lines")
    println("StaticJSON source coverage: $covered/$total lines (100%)")
    return nothing
end

verify_full_coverage(normpath(joinpath(@__DIR__, "..", "src")))
