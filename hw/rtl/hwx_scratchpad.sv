module hwx_scratchpad #(
    parameter int WORDS      = 256,
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = $clog2(WORDS)
) (
    input logic clk_i,
    input logic rst_ni,

    // Port A read/write
    input  logic [ADDR_WIDTH-1:0] a_addr_i,
    input  logic                  a_we_i,
    input  logic [DATA_WIDTH-1:0] a_wdata_i,
    output logic [DATA_WIDTH-1:0] a_rdata_o,

    // Port B read/write
    input  logic [ADDR_WIDTH-1:0] b_addr_i,
    input  logic                  b_we_i,
    input  logic [DATA_WIDTH-1:0] b_wdata_i,
    output logic [DATA_WIDTH-1:0] b_rdata_o

);

  logic [DATA_WIDTH-1:0] mem[0:WORDS-1];

  // Port A: read + write
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_rdata_o <= '0;
    end else begin
      if (a_we_i) begin
        mem[a_addr_i] <= a_wdata_i;
      end
      a_rdata_o <= mem[a_addr_i];
    end
  end

  // Port B: read/write
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      b_rdata_o <= '0;
    end else begin
      if (b_we_i) begin
        mem[b_addr_i] <= b_wdata_i;
      end
      b_rdata_o <= mem[b_addr_i];
    end
  end

endmodule
