// cvxif_hwx_shell.sv
//
// CV-X-IF compliant accelerator shell for HWExplore.
// Accepts CUSTOM_0 (opcode 0x0B) instructions, hands them to a generated
// datapath, waits for completion, and returns the result to the CPU.
//
// FSM states:
//   IDLE         - ready to accept a new instruction from the CPU
//   WAIT_COMMIT  - instruction issued, waiting for CPU commit/kill
//   WAIT_DATAPATH- committed, datapath is running
//   SEND_RESULT  - datapath done, returning result to CPU
import cv32e40x_pkg::*;

module cvxif_hwx_shell (
    input logic clk_i,
    input logic rst_ni,
    input logic stall_i,

    // CV-X-IF Issue Channel
    input  logic        x_issue_req_valid_i,
    output logic        x_issue_req_ready_o,
    input  logic [31:0] x_issue_req_instr_i,  // Raw 32-bit RISC-V instruction
    input  logic [31:0] x_issue_req_rs1_i,
    input  logic [31:0] x_issue_req_rs2_i,
    input  logic [ 4:0] x_issue_req_id_i,     // CPU-assigned instruction tag

    output logic       x_issue_resp_valid_o,
    output logic       x_issue_resp_accept_o,
    output logic [4:0] x_issue_resp_id_o,

    // CV-X-IF Commit Channel
    input logic       x_commit_valid_i,
    input logic [4:0] x_commit_id_i,     // Emitter channel
    input logic       x_commit_kill_i,

    // CV-X-IF Result Channel
    output logic        x_result_valid_o,
    input  logic        x_result_ready_i,
    output logic [ 4:0] x_result_id_o,
    output logic [31:0] x_result_data_o,
    output logic [ 4:0] x_result_rd_o,

    // Datapath interface — connects to hwx_mux
    output logic        dp_start_o,
    output logic        dp_stall_o,
    output logic [31:0] dp_rs1_o,
    output logic [31:0] dp_rs2_o,
    output logic [ 2:0] dp_funct3_o,
    input  logic [31:0] dp_rd_i,
    input  logic        dp_done_i
);

  // --------------------------------------------------------------------------
  // FSM state encoding
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,
    WAIT_COMMIT,
    WAIT_DATAPATH,
    SEND_RESULT
  } state_t;

  state_t state_q, state_n;

  // --------------------------------------------------------------------------
  // Saved instruction context (registered on issue handshake)
  // --------------------------------------------------------------------------
  logic [31:0] saved_rs1_q, saved_rs2_q;
  logic [31:0] saved_instr_q;
  logic [ 4:0] saved_id_q;
  logic [ 4:0] saved_rd_addr_q;

  // --------------------------------------------------------------------------
  // Datapath operand routing
  // --------------------------------------------------------------------------
  assign dp_stall_o  = stall_i;
  assign dp_rs1_o    = (state_q == IDLE) ? x_issue_req_rs1_i : saved_rs1_q;
  assign dp_rs2_o    = (state_q == IDLE) ? x_issue_req_rs2_i : saved_rs2_q;
  assign dp_funct3_o = (state_q == IDLE) ? x_issue_req_instr_i[14:12] : saved_instr_q[14:12];
  // --------------------------------------------------------------------------
  // Combinational FSM
  // --------------------------------------------------------------------------
  always_comb begin
    state_n               = state_q;
    x_issue_req_ready_o   = 1'b0;
    x_issue_resp_valid_o  = 1'b0;
    x_issue_resp_accept_o = 1'b0;
    x_issue_resp_id_o     = x_issue_req_id_i;
    x_result_valid_o      = 1'b0;
    x_result_id_o         = 5'b0;
    x_result_rd_o         = 5'b0;
    x_result_data_o       = 32'b0;
    dp_start_o            = 1'b0;

    case (state_q)

      IDLE: begin
        x_issue_req_ready_o = 1'b1;
        if (x_issue_req_valid_i) begin
          x_issue_resp_valid_o = 1'b1;
          // Accept only CUSTOM_0 instructions (opcode == 0x0B)
          if (x_issue_req_instr_i[6:0] == 7'h0B) begin
            x_issue_resp_accept_o = 1'b1;
            // The cv32e40px can commit in the SAME cycle as issue.
            // Handle that here to avoid missing the commit.
            if (x_commit_valid_i && !x_commit_kill_i) begin
              dp_start_o = 1'b1;
              state_n    = WAIT_DATAPATH;
            end else begin
              state_n = WAIT_COMMIT;
            end
          end else begin
            x_issue_resp_accept_o = 1'b0;
          end
        end
      end

      WAIT_COMMIT: begin
        // In-order coprocessor: process commit without ID matching.
        // The cv32e40px may issue multiple instructions before committing,
        // so a strict ID comparison can deadlock. We handle one instruction
        // at a time, so commit order == issue order.
        if (x_commit_valid_i) begin
          if (x_commit_kill_i) state_n = IDLE;  // Branch mispredict — flush
          else begin
            dp_start_o = 1'b1;  // Kick off the datapath
            state_n    = WAIT_DATAPATH;
          end
        end
      end

      WAIT_DATAPATH: begin
        if (dp_done_i) state_n = SEND_RESULT;
      end

      SEND_RESULT: begin
        x_result_valid_o = 1'b1;
        x_result_id_o    = saved_id_q;
        x_result_rd_o    = saved_rd_addr_q;
        x_result_data_o  = dp_rd_i;
        if (x_result_ready_i) state_n = IDLE;
      end

    endcase
  end

  // --------------------------------------------------------------------------
  // Sequential state and capture registers
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q         <= IDLE;
      saved_rs1_q     <= 32'b0;
      saved_rs2_q     <= 32'b0;
      saved_instr_q   <= 32'b0;
      saved_id_q      <= 5'b0;
      saved_rd_addr_q <= 5'b0;
    end else begin
      state_q <= state_n;

      // Capture operands on the issue handshake
      if (x_issue_req_valid_i && x_issue_req_ready_o) begin
        saved_rs1_q     <= x_issue_req_rs1_i;
        saved_rs2_q     <= x_issue_req_rs2_i;
        saved_instr_q   <= x_issue_req_instr_i;
        saved_id_q      <= x_issue_req_id_i;
        saved_rd_addr_q <= x_issue_req_instr_i[11:7];  // rd field of R-type
      end
    end
  end

endmodule
