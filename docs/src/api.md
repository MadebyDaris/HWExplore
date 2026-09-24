# API Reference

Every exported (and a few key internal) docstring in `HWExplore`, generated from the source. If something you'd expect is missing here, it doesn't have a docstring yet check the corresponding `.jl` file directly, if you download the repo locally you can try building the docs locally since it is a standard Julia package, or see the [Guide to Using HWExplore](@ref) and [Guide to High-Level Synthesis (HLS)](@ref) for the narrative version.

```@autodocs
Modules = [HWExplore, HWExplore.DFG_Builder]
Order = [:module, :type, :macro, :function, :constant]
```
