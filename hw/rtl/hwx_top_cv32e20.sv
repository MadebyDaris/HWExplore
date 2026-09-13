// hwx_top_cv32e20.sv
//
// Top-level wrapper that connects X-HEEP to the HWExplore coprocessor shell.
// This module owns the if_xif interface instance and performs the
// flat-to-interface translation required to bridge cvxif_hwx_shell
// to x_heep_system.

import core_v_mini_mcu_pkg::*;
import xheep_obi_pkg::*;

module hwx_top_cv32e20 (
    input  logic         clk_i,
    input  logic         rst_ni,

    // Instruction memory interface
    output xheep_obi_req_t core_instr_req_o,
    input  xheep_obi_rsp_t core_instr_rsp_i,

    // Data memory interface
    output xheep_obi_req_t core_data_req_o,
    input  xheep_obi_rsp_t core_data_rsp_i,

    // Interrupts
    input logic [31:0] intr_vector_ext_i,

    // Debug
    input logic debug_req_i,

    // Exit value (for simulation end-of-test)
    output logic [31:0] exit_value_o
);

    // CV-X-IF interface instance shared wire bundle X-HEEP and coprocessor shell.
    if_xif #() ext_if ();

    wire boot_select_w = 1'b0;   // 0 = JTAG/Testbench (debug path), 1 = SPI Flash
    
    // Power management loopback with 15-cycle delay
    localparam SWITCH_ACK_LATENCY = 15;
    
    wire cpu_subsystem_powergate_switch_n;
    wire peripheral_subsystem_powergate_switch_n;
    wire [0:0] external_subsystem_powergate_switch_n;
    
    logic [SWITCH_ACK_LATENCY:0] cpu_subsystem_powergate_switch_ack_n;
    logic [SWITCH_ACK_LATENCY:0] peripheral_subsystem_powergate_switch_ack_n;
    logic [0:0] external_subsystem_powergate_switch_ack_n [SWITCH_ACK_LATENCY:0];
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cpu_subsystem_powergate_switch_ack_n <= '0;
            peripheral_subsystem_powergate_switch_ack_n <= '0;
            for (int i = 0; i <= SWITCH_ACK_LATENCY; i++) begin
                external_subsystem_powergate_switch_ack_n[i] <= '0;
            end
        end else begin
            cpu_subsystem_powergate_switch_ack_n[0] <= cpu_subsystem_powergate_switch_n;
            peripheral_subsystem_powergate_switch_ack_n[0] <= peripheral_subsystem_powergate_switch_n;
            external_subsystem_powergate_switch_ack_n[0] <= external_subsystem_powergate_switch_n;
            
            for (int i = 1; i <= SWITCH_ACK_LATENCY; i++) begin
                cpu_subsystem_powergate_switch_ack_n[i] <= cpu_subsystem_powergate_switch_ack_n[i-1];
                peripheral_subsystem_powergate_switch_ack_n[i] <= peripheral_subsystem_powergate_switch_ack_n[i-1];
                external_subsystem_powergate_switch_ack_n[i] <= external_subsystem_powergate_switch_ack_n[i-1];
            end
        end
    end
    
    x_heep_system #(
        .EXT_XBAR_NMASTER (0),
        .AO_SPC_NUM       (0)
    ) u_x_heep (
        .hart_id_i           (32'h0),
        .xheep_instance_id_i (32'h0),

        .clk_i  (clk_i),
        .rst_ni (rst_ni),

        // Memory
        .ext_core_instr_req_o  (core_instr_req_o),
        .ext_core_instr_resp_i (core_instr_rsp_i),
        .ext_core_data_req_o   (core_data_req_o),
        .ext_core_data_resp_i  (core_data_rsp_i),

        // Interrupts
        .intr_vector_ext_i     (intr_vector_ext_i),
        .intr_ext_peripheral_i (1'b0),

        // Boot Select (1 = JTAG/Testbench loop, 0 = SPI Flash)
        .boot_select_i (boot_select_w),

        // Power management
        .cpu_subsystem_powergate_switch_no            (cpu_subsystem_powergate_switch_n),
        .cpu_subsystem_powergate_switch_ack_ni        (cpu_subsystem_powergate_switch_ack_n[SWITCH_ACK_LATENCY]),
        .peripheral_subsystem_powergate_switch_no     (peripheral_subsystem_powergate_switch_n),
        .peripheral_subsystem_powergate_switch_ack_ni (peripheral_subsystem_powergate_switch_ack_n[SWITCH_ACK_LATENCY]),
        .external_subsystem_powergate_switch_no       (external_subsystem_powergate_switch_n),
        .external_subsystem_powergate_switch_ack_ni   (external_subsystem_powergate_switch_ack_n[SWITCH_ACK_LATENCY]),

        // Debug
        .ext_debug_master_req_o  (),
        .ext_debug_master_resp_i ('0),

        // DMA external ports (tie off)
        .ext_dma_read_req_o   (),
        .ext_dma_read_resp_i  ('0),
        .ext_dma_write_req_o  (),
        .ext_dma_write_resp_i ('0),
        .ext_dma_addr_req_o   (),
        .ext_dma_addr_resp_i  ('0),
        .hw_fifo_req_o        (),
        .hw_fifo_resp_i       ('0),
        .ext_dma_slot_tx_i    ('0),
        .ext_dma_slot_rx_i    ('0),
        .ext_dma_stop_i       ('0),
        .hw_fifo_done_i       ('0),
        .dma_done_o           (),

        // AO/peripheral slave (tie off)
        .ext_ao_peripheral_req_i     ('0),
        .ext_ao_peripheral_resp_o    (),
        .ext_peripheral_slave_req_o  (),
        .ext_peripheral_slave_resp_i ('0),
        
        // External Master
        .ext_xbar_master_req_i       ('0),
        .ext_xbar_master_resp_o      (),
        
        // Unused power domains
        .external_subsystem_powergate_iso_no   (),
        .external_subsystem_rst_no             (),
        .external_ram_banks_set_retentive_no   (),
        .external_subsystem_clkgate_en_no      (),

        // Exit
        .exit_value_o (exit_value_o),

        // CV-X-IF: connect the interface instance
        .xif_compressed_if (ext_if),
        .xif_issue_if      (ext_if),
        .xif_commit_if     (ext_if),
        .xif_mem_if        (ext_if),
        .xif_mem_result_if (ext_if),
        .xif_result_if     (ext_if)
    );

    // HWExplore Coprocessor Shell

    logic        shell_start;
    logic [31:0] shell_rs1, shell_rs2;
    logic [2:0]  shell_funct3;
    logic [31:0] shell_rd;
    logic        shell_done;

    // Tie off unused CV-X-IF interface fields

    logic shell_issue_accept;

    cvxif_hwx_shell u_shell (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),

        // Issue channel
        .x_issue_req_valid_i   (ext_if.issue_valid),
        .x_issue_req_ready_o   (ext_if.issue_ready),
        .x_issue_req_instr_i   (ext_if.issue_req.instr),
        .x_issue_req_rs1_i     (ext_if.issue_req.rs[0]),
        .x_issue_req_rs2_i     (ext_if.issue_req.rs[1]),
        .x_issue_req_id_i      (ext_if.issue_req.id),

        .x_issue_resp_valid_o  (),
        .x_issue_resp_accept_o (shell_issue_accept),
        .x_issue_resp_id_o     (),

        // Commit channel
        .x_commit_valid_i (ext_if.commit_valid),
        .x_commit_id_i    (ext_if.commit.id),
        .x_commit_kill_i  (ext_if.commit.commit_kill),

        // Result channel
        .x_result_valid_o (ext_if.result_valid),
        .x_result_ready_i (ext_if.result_ready),
        .x_result_id_o    (ext_if.result.id),
        .x_result_data_o  (ext_if.result.data),
        .x_result_rd_o    (ext_if.result.rd),

        // Datapath interface → mux
        .dp_start_o  (shell_start),
        .dp_stall_o  (),
        .dp_rs1_o    (shell_rs1),
        .dp_rs2_o    (shell_rs2),
        .dp_funct3_o (shell_funct3),
        .dp_rd_i     (shell_rd),
        .dp_done_i   (shell_done)
    );

    // HWExplore Dispatcher Mux routes shell to datapath and back to shell.
    hwx_mux u_mux (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .stall_i  (1'b0),   // no stalling in this PoC
        .start_i  (shell_start),
        .funct3_i (shell_funct3),
        .rs1_i    (shell_rs1),
        .rs2_i    (shell_rs2),
        .rd_o     (shell_rd),
        .done_o   (shell_done)
    );

    // Issue response
    assign ext_if.issue_resp.accept    = shell_issue_accept;
    assign ext_if.issue_resp.writeback = 1'b1;   // We write back to rd
    assign ext_if.issue_resp.dualwrite = 1'b0;
    assign ext_if.issue_resp.dualread  = 3'b0;
    assign ext_if.issue_resp.loadstore = 1'b0;
    assign ext_if.issue_resp.ecswrite  = 1'b0;
    assign ext_if.issue_resp.exc       = 1'b0;

    // Result — extra fields
    assign ext_if.result.we      = 1'b1;         // Enable register write
    assign ext_if.result.ecsdata = 6'b0;
    assign ext_if.result.ecswe   = 3'b0;
    assign ext_if.result.exc     = 1'b0;
    assign ext_if.result.exccode = 6'b0;
    assign ext_if.result.err     = 1'b0;
    assign ext_if.result.dbg     = 1'b0;

    // Compressed channel — we don't support compressed custom instructions,
    // but we MUST be ready to accept and reject them, otherwise the CPU IF stage hangs!
    assign ext_if.compressed_ready = 1'b1;
    assign ext_if.compressed_resp  = '0;

    // Memory channel — not used
    assign ext_if.mem_valid = 1'b0;
    assign ext_if.mem_req   = '0;


endmodule