# docs/make.jl
#
# Build this documentation locally with:
#   julia --project=docs -e 'using Pkg; Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# then open docs/build/index.html.
#
# On CI (see .github/workflows/docs.yml), the same build is then uploaded and
# deployed straight to GitHub Pages via actions/deploy-pages -- no gh-pages
# branch and no Jekyll involved, so this script itself only ever builds; it
# never pushes or deploys anything on its own.
#
# HWExplore is not (yet) a registered package. `Pkg.develop`-ing it here,
# rather than just pushing the repo root onto LOAD_PATH, makes `instantiate()`
# also resolve and install *its* dependencies (MacroTools, IRTools, LLVM,
# GPUCompiler, DataStructures, ...) into docs/Manifest.toml -- without this,
# `using HWExplore` fails to precompile on a fresh checkout/CI runner that
# doesn't already have those installed globally, even though it looks fine
# locally on a machine where they happen to already be on the default
# environment's load path.

import Pkg
Pkg.develop(Pkg.PackageSpec(path = joinpath(@__DIR__, "..")))

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
