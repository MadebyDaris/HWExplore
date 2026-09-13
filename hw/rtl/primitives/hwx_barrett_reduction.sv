// Barrett Reduction Primitive for HWExplore
//
// Computes:  r = x mod MODULUS  using Barrett's method.
//
// Standard HWExplore datapath interface: clk_i, rst_ni, stall_i, start_i,
// rs1_i (x), rs2_i (unused), rd_o (r), done_o
//
// Pipeline: 3 stages
//   Stage 1: compute q_approx = (x * K) >> WORD_WIDTH
//   Stage 2: compute r = x - q_approx * MODULUS
//   Stage 3: final correction (subtract MODULUS if r >= MODULUS)
//
// done_o asserts 3 cycles after start_i (matches mac_plus_5 timing).

module hwx_barrett_reduction #(
    parameter int WORD_WIDTH = 32,
    parameter int MODULUS    = 12289,
    parameter int K          = 349496  // floor(2^32 / 12289)
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  stall_i,
    input  logic                  start_i,
    input  logic [WORD_WIDTH-1:0] rs1_i,    // x — value to reduce
    input  logic [WORD_WIDTH-1:0] rs2_i,    // unused
    output logic [WORD_WIDTH-1:0] rd_o,
    output logic                  done_o
);

  // Pipeline registers
  logic [  WORD_WIDTH-1:0] x_r1;
  logic [  WORD_WIDTH-1:0] q_approx_r;
  logic [  WORD_WIDTH-1:0] r_r;
  logic [             2:0] done_shift;

  // compute q_approx = (x * K) >> WORD_WIDTH
  logic [2*WORD_WIDTH-1:0] prod;
  logic [  WORD_WIDTH-1:0] q_approx;

  assign prod     = rs1_i * K;
  assign q_approx = prod[2*WORD_WIDTH-1:WORD_WIDTH];  // upper half = floor(x*K / 2^W)

  // compute r = x - q * MODULUS
  logic [WORD_WIDTH-1:0] r_stage2;
  assign r_stage2 = x_r1 - q_approx_r * MODULUS;

  // final correction
  logic [WORD_WIDTH-1:0] r_final;
  assign r_final = (r_r >= MODULUS) ? (r_r - MODULUS) : r_r;

  // Sequential logic
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      x_r1       <= '0;
      q_approx_r <= '0;
      r_r        <= '0;
      done_shift <= '0;
      rd_o       <= '0;
    end else if (!stall_i) begin
      // Stage 1 → Stage 2
      x_r1       <= rs1_i;
      q_approx_r <= q_approx;
      // Stage 2 → Stage 3
      r_r        <= r_stage2;
      // done_o shift register (3-cycle latency)
      done_shift <= {done_shift[1:0], start_i};
      // output always reflects current pipeline tail
      rd_o       <= r_final;
    end
  end

  assign done_o = done_shift[2];

endmodule
