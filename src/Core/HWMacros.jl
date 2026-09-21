# HWMacros.jl
# Macros for describing hardware in plain Julia. Two kinds:
#     @unroll        replicate a constant-bound loop body: full, or by a factor
#     @tree_reduce   rebalance operation chain into a log-depth tree
#   Synthesis options (recorded next to the function, consumed by hw_compile):
#     @hwkernel      name / resource-sharing budget / vector ports / tree
#   hw_compile(f; ...)   Julia function -> DFG -> schedule -> SystemVerilog
#
# Everything here is integer (wrapping) arithmetic

export @unroll, @tree_reduce, @hwkernel, hw_compile, HWKernelConfig, hw_kernel_config

const _INT_CTORS = (:Int, :Int8, :Int16, :Int32, :Int64, :UInt8, :UInt16, :UInt32, :UInt64)

# Fold a literal-only integer expression (`3`, `Int32(3)`, `2*4`, `1+Int32(1)`)
# to an Int, or `nothing` if it contains anything that isn't a constant.
function _const_int(ex)
    ex isa Integer && return Int(ex)
    if ex isa Expr && ex.head == :call
        f = ex.args[1]
        f in _INT_CTORS && length(ex.args) == 2 && return _const_int(ex.args[2])
        vals = Union{Int,Nothing}[_const_int(a) for a in ex.args[2:end]]
        any(isnothing, vals) && return nothing
        v = Int[x for x in vals]
        f == :+ && return sum(v)
        f == :* && return prod(v)
        f == :- && return length(v) == 1 ? -v[1] : v[1] - sum(v[2:end])
        (f == :÷ || f == :div) && length(v) == 2 && v[2] != 0 && return v[1] ÷ v[2]
    end
    return nothing
end

function _need_int(ex, msg)
    v = _const_int(ex)
    v === nothing && error(msg)
    return v
end

_subst(ex, var::Symbol, repl) = MacroTools.postwalk(x -> x === var ? repl : x, ex)

_has_symbol(ex, s::Symbol) = (found = Ref(false); MacroTools.postwalk(x -> (x === s && (found[] = true); x), ex); found[])

function _forbid_control_flow(body)
    MacroTools.postwalk(body) do x
        x isa Expr && x.head in (:break, :continue, :return) &&
            error("@unroll: `$(x.head)` inside an unrolled loop body is not supported")
        x
    end
end

# @unroll

# `acc += rhs` / `acc = acc + rhs` as (acc, op, rhs), else nothing.
function _accumulate_form(stmt)
    stmt isa Expr || return nothing
    ops = Dict(:(+=) => :+, :(*=) => :*, :(&=) => :&, :(|=) => :|, :(⊻=) => :⊻)
    if haskey(ops, stmt.head) && stmt.args[1] isa Symbol
        return (stmt.args[1], ops[stmt.head], stmt.args[2])
    end
    if stmt.head == :(=) && stmt.args[1] isa Symbol
        r = stmt.args[2]
        if r isa Expr && r.head == :call && length(r.args) == 3 && r.args[1] in (:+, :*, :&, :|, :⊻) &&
           r.args[2] === stmt.args[1]
            return (stmt.args[1], r.args[1], r.args[3])
        end
    end
    return nothing
end

_statements(body) = body isa Expr && body.head == :block ?
    [s for s in body.args if !(s isa LineNumberNode)] : Any[body]

function _unroll(loop, factor::Int, T, tree::Bool)
    loop isa Expr && loop.head == :for ||
        error("@unroll expects a `for` loop, got: $(loop isa Expr ? loop.head : typeof(loop))")
    spec, body = loop.args[1], loop.args[2]
    (spec isa Expr && spec.head == :(=) && spec.args[1] isa Symbol) ||
        error("@unroll supports one loop variable: `for i in lo:hi` (nest @unroll for more)")
    var, rng = spec.args[1], spec.args[2]
    (rng isa Expr && rng.head == :call && rng.args[1] == :(:) && length(rng.args) in (3, 4)) ||
        error("@unroll needs a literal range `lo:hi` or `lo:step:hi`, got: $rng")
    lo, step, hi = length(rng.args) == 3 ?
        (_const_int(rng.args[2]), 1, _const_int(rng.args[3])) :
        (_const_int(rng.args[2]), _const_int(rng.args[3]), _const_int(rng.args[4]))
    (lo === nothing || step === nothing || hi === nothing || step == 0) &&
        error("@unroll needs compile-time-constant, non-zero-step loop bounds; got $rng")
    _forbid_control_flow(body)
    vals = collect(lo:step:hi)
    lit(v) = :($T($v))

    # Reduction-tree unroll: `acc += f(i)` becomes acc = acc ⊕ balanced_tree(f(i₁)…f(iₙ)).
    if tree
        stmts = _statements(body)
        form = length(stmts) == 1 ? _accumulate_form(stmts[1]) : nothing
        form === nothing &&
            error("@unroll tree=true needs a body that is exactly one accumulation, e.g. `acc += a[i]*b[i]`")
        acc, op, rhs = form
        _has_symbol(rhs, acc) && error("@unroll tree=true: the accumulated expression must not read `$acc`")
        isempty(vals) && return :(nothing)
        terms = [_subst(rhs, var, lit(v)) for v in vals]
        return :($acc = $(Expr(:call, op, acc, _balance(op, terms))))
    end

    if factor <= 0 || factor >= length(vals)          # full unroll
        return Expr(:block, [_subst(body, var, lit(v)) for v in vals]...)
    end
    step > 0 || error("@unroll factor=n needs a positive step")
    groups, rem = divrem(length(vals), factor)
    iv = gensym(Symbol(var, "_u"))
    copies = [_subst(body, var, k == 0 ? iv : :($iv + $(lit(k * step)))) for k in 0:factor-1]
    last_group_start = lo + (groups - 1) * factor * step
    tail = [_subst(body, var, lit(v)) for v in vals[end-rem+1:end]]
    return quote
        $iv = $(lit(lo))
        while $iv <= $(lit(last_group_start))
            $(copies...)
            $iv += $(lit(factor * step))
        end
        $(tail...)
    end
end

"""
    @unroll [factor=n] [tree=true] [type=Int32] for i in lo:hi ... end

Unroll a constant-bound loop at macro-expansion time. With no options the loop
is fully unrolled into straight-line code, exposing every iteration to the
scheduler at once. `factor=n` unrolls by `n`, leaving a counted `while` loop
with `n` copies of the body per pass (the FSM backend synthesizes that as a
smaller state machine doing `n` iterations' work per trip) plus a literal
remainder. `tree=true` recognizes an accumulation body (`acc += expr(i)`) and
rewrites the serial chain into `acc = acc + balanced_tree(expr(1)…expr(n))`.
"""
macro unroll(args...)
    isempty(args) && error("@unroll requires a loop")
    factor, tree, T = 0, false, :Int32
    for a in args[1:end-1]
        if a == :full
            factor = 0
        elseif a isa Expr && a.head == :(=) && a.args[1] == :factor
            factor = _need_int(a.args[2], "@unroll factor must be an integer literal")
        elseif a isa Expr && a.head == :(=) && a.args[1] == :tree
            tree = a.args[2] === true ? true : error("@unroll tree must be true or false")
        elseif a isa Expr && a.head == :(=) && a.args[1] == :type
            T = a.args[2]
        else
            error("@unroll: unknown option `$a`; expected full, factor=n, tree=true, type=T")
        end
    end
    return esc(_unroll(args[end], factor, T, tree))
end

# @tree_reduce

const _ASSOC_OPS = (:+, :*, :&, :|, :⊻)

_flatten(op, ex) = (ex isa Expr && ex.head == :call && ex.args[1] === op && length(ex.args) >= 3) ?
    reduce(vcat, [_flatten(op, a) for a in ex.args[2:end]]) : Any[ex]

function _balance(op, xs)
    length(xs) == 1 && return xs[1]
    mid = cld(length(xs), 2)
    return Expr(:call, op, _balance(op, xs[1:mid]), _balance(op, xs[mid+1:end]))
end

function _tree_reduce(ex)
    ex isa Expr || return ex
    if ex.head == :call && ex.args[1] in _ASSOC_OPS && length(ex.args) >= 3
        op = ex.args[1]
        operands = [_tree_reduce(x) for x in _flatten(op, ex)]
        return _balance(op, operands)
    end
    return Expr(ex.head, [_tree_reduce(a) for a in ex.args]...)
end

"""
    @tree_reduce expr

Rewrite every chain of `+`, `*`, `&`, `|` in `expr` (an expression, a
block, or a whole function definition) into a balanced binary tree. Julia
evaluates `a+b+c+d` left to right — three dependent adds; the tree needs two
levels, which is one fewer scheduler cycle and lets the two lower adds run in
parallel. Exact for fixed-width integers (associative, commutative); do not
use on floating point.
"""
macro tree_reduce(ex)
    return esc(_tree_reduce(ex))
end

# @hwkernel + hw_compile

const _OP_BY_NAME = Dict{Symbol,Opcode}(
    :add => OP_ADD, :sub => OP_SUB, :mul => OP_MUL, :mod => OP_MOD,
    :shl => OP_SHL, :shr => OP_SHR, :and => OP_AND, :or => OP_OR, :xor => OP_XOR)

"""
    HWKernelConfig(name, share, tree, argtypes)

Synthesis options recorded by `@hwkernel` for a function; `hw_compile` reads
them and lets keyword arguments override each one.
"""
struct HWKernelConfig
    name::Union{Nothing,String}
    share::Dict{Opcode,Int}
    tree::Bool
    argtypes::Union{Nothing,Type}
end

const HW_KERNELS = Dict{Symbol,HWKernelConfig}()

function register_kernel_config!(fname::Symbol, name, share, tree, argtypes)
    HW_KERNELS[fname] = HWKernelConfig(name, Dict{Opcode,Int}(share), tree, argtypes)
    return nothing
end

"""hw_kernel_config(f) -> the `HWKernelConfig` recorded by `@hwkernel`, or `nothing`."""
hw_kernel_config(f) = get(HW_KERNELS, nameof(f), nothing)

# `(mul=1, add=2)` / `(mul=1)` / `Dict(OP_MUL => 1)` → Dict{Opcode,Int}
function _to_budget(x)::Dict{Opcode,Int}
    out = Dict{Opcode,Int}()
    for (k, v) in pairs(x)
        op = k isa Opcode ? k : get(_OP_BY_NAME, Symbol(lowercase(string(k))), nothing)
        op === nothing && error("[HWExplore] unknown resource class `$k`; expected one of $(sort!(collect(keys(_OP_BY_NAME))))")
        out[op] = Int(v)
    end
    return out
end

function _kv_options(ex, what)::Vector{Pair{Symbol,Any}}
    ex isa Expr && ex.head == :(=) && return [ex.args[1] => ex.args[2]]
    (ex isa Expr && ex.head == :tuple && all(a -> a isa Expr && a.head == :(=), ex.args)) ||
        error("@hwkernel $what= expects (name=value, ...), got: $ex")
    return [a.args[1] => a.args[2] for a in ex.args]
end

"""
    @hwkernel [name="m"] [share=(mul=1,)] [tree=true] [vec=(a=4,)] function f(...) ... end

Define `f` normally and record synthesis options for it.

- `name="m"`     Verilog module name (default: the function name)
- `share=(mul=1, add=2)`  functional-unit budget per operator class; the
                 emitter shares units and inserts operand muxes (`hw_compile`)
- `tree=true`    run `@tree_reduce` over the body
- `vec=(a=4,)`   fixed-size vector ports: argument `a::T` becomes scalar
                 ports `a_1 … a_4::T`, and `a[k]` with a compile-time-constant
                 `k` (e.g. from `@unroll`) becomes `a_k`

`f` remains an ordinary Julia function of the *expanded* scalar arguments, so
it can be called on a CPU as the golden model for the generated hardware.
"""
macro hwkernel(args...)
    isempty(args) && error("@hwkernel requires a function definition")
    fdef = args[end]
    name_opt, share, tree, vecs = nothing, Dict{Opcode,Int}(), false, Dict{Symbol,Int}()
    for o in args[1:end-1]
        o isa Expr && o.head == :(=) || error("@hwkernel: expected key=value option, got: $o")
        key, val = o.args
        if key == :name
            val isa AbstractString || error("@hwkernel name= must be a string literal")
            name_opt = String(val)
        elseif key == :share
            share = _to_budget(Dict(k => _need_int(v, "@hwkernel share= values must be integer literals")
                                    for (k, v) in _kv_options(val, "share")))
        elseif key == :tree
            val isa Bool || error("@hwkernel tree= must be true or false")
            tree = val
        elseif key == :vec
            for (k, v) in _kv_options(val, "vec")
                n = _const_int(v)
                (n !== nothing && n >= 1) || error("@hwkernel vec= sizes must be positive integer literals")
                vecs[k] = n
            end
        else
            error("@hwkernel: unknown option `$key`; expected name, share, tree, vec")
        end
    end

    d = MacroTools.splitdef(fdef)
    fname = d[:name]
    fname isa Symbol || error("@hwkernel: function name must be a plain identifier")

    # Vector ports: expand signature, then rewrite constant-index reads in the body.
    new_args, arg_types = Any[], Any[]
    for a in d[:args]
        aname, atype, _, _ = MacroTools.splitarg(a)
        if haskey(vecs, aname)
            for k in 1:vecs[aname]
                push!(new_args, atype === :Any ? Symbol(aname, "_", k) : :($(Symbol(aname, "_", k))::$atype))
                push!(arg_types, atype)
            end
        else
            push!(new_args, a)
            push!(arg_types, atype)
        end
    end
    body = macroexpand(__module__, d[:body]; recursive = true)   # let @unroll etc. run first
    if !isempty(vecs)
        body = MacroTools.postwalk(body) do x
            if x isa Expr && x.head == :ref && x.args[1] isa Symbol && haskey(vecs, x.args[1])
                v, idx = x.args[1], x.args[2:end]
                k = length(idx) == 1 ? _const_int(idx[1]) : nothing
                (k !== nothing && 1 <= k <= vecs[v]) ||
                    error("@hwkernel: `$v[$(join(idx, ", "))]` is not a constant index in 1:$(vecs[v]); " *
                          "unroll the loop (`@unroll for ...`) so every index is a compile-time constant")
                return Symbol(v, "_", k)
            end
            x
        end
    end
    tree && (body = _tree_reduce(body))
    d[:args], d[:body] = new_args, body

    argtypes = any(t -> t === :Any, arg_types) ? nothing : :(Tuple{$(arg_types...)})
    return quote
        $(esc(MacroTools.combinedef(d)))
        $register_kernel_config!($(QuoteNode(fname)), $name_opt, $share, $tree, $(esc(argtypes)))
        $(esc(fname))
    end
end

"""
    hw_compile(f; argtypes, name, share, outdir=".", path=nothing) -> NamedTuple

Julia function → SystemVerilog file. Options recorded by `@hwkernel` are the
defaults; every keyword overrides its recorded value, so a design-space sweep
is just a loop over `share`:

    for muls in 1:4
        hw_compile(dot4; name="dot4_m\$muls", share=(mul=muls,), outdir="out")
    end

Returns `(name, path, graph, latency, share, kind)`; `kind` is `:pipeline` or
`:fsm` (functions with loops go through the FSM backend, which ignores `share`).
"""
function hw_compile(f; argtypes = nothing, name = nothing, share = :recorded,
                    outdir::AbstractString = ".", path = nothing)
    cfg = hw_kernel_config(f)
    argtypes = argtypes !== nothing ? argtypes : (cfg === nothing ? nothing : cfg.argtypes)
    argtypes === nothing && error("[HWExplore] hw_compile($(nameof(f))): pass argtypes=Tuple{...} " *
                                  "(or annotate every argument under @hwkernel)")
    modname = name !== nothing ? String(name) :
              (cfg !== nothing && cfg.name !== nothing ? cfg.name : string(nameof(f)))
    budget = share === :recorded ? (cfg === nothing ? Dict{Opcode,Int}() : cfg.share) :
             (share === nothing ? Dict{Opcode,Int}() : _to_budget(share))
    file = path !== nothing ? String(path) : joinpath(outdir, modname * ".sv")
    mkpath(dirname(abspath(file)))

    graph, fsm = extract_and_translate(f, argtypes; name = modname)
    has_loop = any(n.op == OP_REG for n in values(graph.nodes))
    if has_loop
        isempty(budget) || @warn "hw_compile: `share` is ignored for looping kernels (FSM backend)"
        schedule_asap!(graph)
        emit_fsm_verilog(graph, fsm, file)
    elseif !isempty(budget)
        emit_verilog(graph, file; share = budget)
    else
        schedule_asap!(graph)
        emit_verilog(graph, file)
    end
    return (name = modname, path = file, graph = graph, latency = graph.latency,
            share = budget, kind = has_loop ? :fsm : :pipeline)
end
