using HWExplore

# Graph: mac_plus_5  =>  (rs1 * rs2) + 5

node_1 = DFGNode(1, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict())
node_2 = DFGNode(2, OP_ARG,   32, [],    nothing, 0, 0, nothing, Dict())
node_3 = DFGNode(3, OP_CONST, 32, [],    5,       0, 0, nothing, Dict())
node_4 = DFGNode(4, OP_MUL,   32, [1,2], nothing, 0, 0, nothing, Dict())
node_5 = DFGNode(5, OP_ADD,   32, [4,3], nothing, 0, 0, nothing, Dict())
node_6 = DFGNode(6, OP_RET,   32, [5],   nothing, 0, 0, nothing, Dict())

my_graph = HWGraph(
    "mac_plus_5",
    Dict(1 => node_1, 2 => node_2, 3 => node_3, 4 => node_4, 5 => node_5, 6 => node_6),
    [1, 2],
    [6]
)