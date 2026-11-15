# Synth.jl: quick Yosys + ABC synthesis of a generated engine against a liberty file.
#
# This is logic synthesis only (no placement, no wires), so area is cell area and
# delay is ABC's critical-path estimate. Good for comparing design points; real
# post-layout numbers need the OpenROAD flow.

export find_liberty, synth_dot, SynthResult

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

"""
    find_liberty(pdk) -> path

- `"sg13g2"`: `\$HWX_LIBERTY`, else
  `\$PDK_ROOT/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib`
  (a `ciel`/`volare` install), else `synth/pdk/sg13g2_stdcell_typ_1p20V_25C.lib`.
- `"sky130"`: the Sky130 liberty vendored in the X-HEEP submodule.
- anything else is treated as a path to a `.lib` file.
"""
function find_liberty(pdk::AbstractString)
    haskey(ENV, "HWX_LIBERTY") && return ENV["HWX_LIBERTY"]
    p = lowercase(pdk)
    if p == "sg13g2"
        name = "sg13g2_stdcell_typ_1p20V_25C.lib"
        cands = String[]
        haskey(ENV, "PDK_ROOT") && push!(cands, joinpath(ENV["PDK_ROOT"], "ihp-sg13g2", "libs.ref", "sg13g2_stdcell", "lib", name))
        push!(cands, joinpath(REPO_ROOT, "synth", "pdk", name))
        for c in cands
            isfile(c) && return c
        end
        error("SG13G2 liberty not found. Install the IHP PDK (e.g. `ciel enable --pdk-family ihp-sg13g2 ...`) " *
              "and set PDK_ROOT, put $name in synth/pdk/, or set HWX_LIBERTY.")
    elseif p == "sky130"
        lib = joinpath(REPO_ROOT, "hw", "ext_xheep", "hw", "asic", "sky130", "sky130_fd_sc_lp__ss_150C_1v65.lib")
        isfile(lib) || error("Sky130 liberty not found at $lib (is the hw/ext_xheep submodule checked out?)")
        return lib
    end
    isfile(pdk) || error("unknown PDK '$pdk' and no such liberty file")
    return pdk
end

struct SynthResult
    area_um2::Float64
    cells::Int
    delay_ps::Float64
    flops::Int
    log::String
end

"""
    synth_dot(cfg; pdk="sg13g2", dir=mktempdir()) -> SynthResult

Flatten, synthesize and map `cfg`'s RTL to the PDK's standard cells; report
cell area, cell count, flip-flop count and ABC's critical-path delay.
"""
function synth_dot(c::DotConfig; pdk::AbstractString="sg13g2", dir::AbstractString=mktempdir(),
                   rtl::Union{Nothing,String}=nothing)
    Sys.which("yosys") === nothing && error("yosys not found on PATH")
    lib = find_liberty(pdk)
    rtl === nothing && (rtl = emit_dot(c, dir))
    ys = joinpath(dir, "$(c.name).ys")
    write(ys, """
    read_verilog -sv $rtl
    synth -flatten -top $(c.name)
    dfflibmap -liberty $lib
    abc -liberty $lib -script +strash;dch,-f;map,-M,1;topo;dnsize;stime,-p
    opt_clean
    stat -liberty $lib
    """)
    log = read(ignorestatus(`yosys -q -l $(joinpath(dir, "$(c.name).synth.log")) -s $ys`), String)
    log = read(joinpath(dir, "$(c.name).synth.log"), String)
    area = match(r"Chip area for (?:top )?module.*?:\s*([0-9.]+)", log)
    area === nothing && error("synthesis failed; see $(joinpath(dir, "$(c.name).synth.log"))")
    # Only the final `stat -liberty` block: "<count> <area> cells", then one line per cell type.
    cm = collect(eachmatch(r"^\s*(\d+)\s+\S+\s+cells$"m, log))
    isempty(cm) && error("could not parse cell count from yosys log")
    cells = parse(Int, cm[end][1])
    block = log[cm[end].offset:area.offset]
    flops = sum((parse(Int, m[1]) for m in eachmatch(r"^\s*(\d+)\s+\S+\s+\S*(?:df|DF|dff|DFF)\S*$"m, block)); init=0)
    delays = [parse(Float64, m[1]) for m in eachmatch(r"Delay\s*=\s*([0-9.]+)\s*ps", log)]
    return SynthResult(parse(Float64, area[1]), cells, isempty(delays) ? NaN : maximum(delays), flops, log)
end
