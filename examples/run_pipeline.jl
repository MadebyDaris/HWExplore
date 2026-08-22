using NexusV

# Define the function
f(a::Int32, b::Int32) = Base.add_int(Base.mul_int(a, b), Int32(5))

function f_1(a::Int32, b::Int32)
    c = a + b
    d = a - b
    e = c * d
    f = e + 10
    return f
end

# Synthesize it
println("Synthesizing function to DFG...")
graph, fsm = extract_and_translate(f_1, Tuple{Int32,Int32}; name="mac_plus_5")

# Schedule it
println("Scheduling ASAP...")
schedule_asap!(graph)

# Emit Verilog
filepath = joinpath(@__DIR__, "hw", "rtl", "f_1.sv")
println("Emitting Verilog to $filepath...")
emit_verilog(graph, filepath)

println("Done!")
