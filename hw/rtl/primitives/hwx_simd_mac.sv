// hwx_simd_mac SIMD multiply-accumulate primitive
//
// Computes:  acc += Σ(a_lane[i] * b_lane[i])  across LANES
//
// Parameters:
//   LANES      — number of SIMD lanes (default 4)
//   DATA_WIDTH — bit width per lane element (default 8)
//
// Pipeline: 3 stages
//   Stage 1: per-lane multiply
//   Stage 2: reduction sum
//   Stage 3: accumulate + output
//
// done_o asserts 3 cycles after start_i (result valid same cycle as done_o).

module hwx_simd_mac #(
    parameter int LANES      = 4,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     start_i,
    input  logic                     stall_i,
    input  logic [LANES*DATA_WIDTH-1:0] rs1_i,
    input  logic [LANES*DATA_WIDTH-1:0] rs2_i,
    output logic [31:0]                 rd_o,
    output logic                     done_o
);

    localparam int PROD_WIDTH = DATA_WIDTH * 2;

    logic signed [PROD_WIDTH-1:0] prod [LANES-1:0];
    logic signed [PROD_WIDTH-1:0] prod_r [LANES-1:0];

    genvar i;
    generate
        for (i = 0; i < LANES; i++) begin : g_mul
            assign prod[i] = $signed(rs1_i[i*DATA_WIDTH +: DATA_WIDTH]) *
                             $signed(rs2_i[i*DATA_WIDTH +: DATA_WIDTH]);
        end
    endgenerate

    logic signed [ACC_WIDTH-1:0] sum_comb;
    logic signed [ACC_WIDTH-1:0] sum_r;

    /* verilator lint_off WIDTHEXPAND */
    always_comb begin
        sum_comb = '0;
        for (int j = 0; j < LANES; j++) begin
            sum_comb += $signed(prod_r[j]);
        end
    end
    /* verilator lint_on WIDTHEXPAND */

    logic signed [ACC_WIDTH-1:0] acc_q;
    logic [2:0]                  done_shift;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            acc_q      <= '0;
            rd_o       <= '0;
            done_shift <= '0;
        end else if (!stall_i) begin
            // Stage 1 → Stage 2
            for (int k = 0; k < LANES; k++) begin
                prod_r[k] <= prod[k];
            end
            sum_r <= sum_comb;

            // Stage 3: accumulate + output (sum_r valid 2 cycles after start)
            if (done_shift[1]) begin
                acc_q <= acc_q + sum_r;
                rd_o  <= acc_q + sum_r;
            end

            done_shift <= {done_shift[1:0], start_i};
        end
    end

    assign done_o = done_shift[2];

endmodule