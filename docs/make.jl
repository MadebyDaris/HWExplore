# docs/make.jl
#
# Build this documentation locally with:
#   julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# then open docs/build/index.html.
#
# HWExplore is not (yet) a registered package, so this adds the repository
# root to LOAD_PATH directly rather than requiring `Pkg.develop` as a separate
# step first -- `julia --project=docs docs/make.jl` works standalone against
# an uncommitted local checkout.

push!(LOAD_PATH, joinpath(@__DIR__, ".."))

using Documenter
using HWExplore

DocMeta.setdocmeta!(HWExplore, :DocTestSetup, :(using HWExplore); recursive = true)

makedocs(;
    modules = [HWExplore, HWExplore.DFG_Builder],
    authors = "Daris Idirene <daris.idirene@gmail.com> and contributors",
    sitename = "HWExplore.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Installation" => "install.md",
        "Guide to Using HWExplore" => "guide.md",
        "Guide to High-Level Synthesis (HLS)" => "hls_guide.md",
        "API Reference" => "api.md",
    ],
    # No strict checkdocs: several exported symbols (Opcode, PrimitiveSpec,
    # schedule_asap!, ...) don't have docstrings yet. Turning this on is a
    # reasonable follow-up once the API reference is meant to be exhaustive,
    # not just "everything that's documented so far".
    checkdocs = :none,
)
