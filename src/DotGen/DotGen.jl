# DotGen.jl: block dot-product engine generator (formats → bit-exact model → RTL → verification).
#
# Self-contained on purpose: no dependencies beyond Base, so `bin/hwx` can load
# it directly without pulling in HWExplore's LLVM/GPUCompiler frontend.
module DotGen

using Random

include("Formats.jl")
include("Config.jl")
include("RefModel.jl")
include("Emitter.jl")
include("Verify.jl")
include("Synth.jl")
include("Explore.jl")

end # module DotGen
