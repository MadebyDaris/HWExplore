// hwx_mont_adapter — stateful wrapper for hwx_montgomery_multiplier
//
// The native Montgomery module uses multi-port memory interfaces. This adapter
// provides local register files and a stateful control interface:
//
// Stateful ports (set via funct3 commands before CMD_START):
//   addr_i   — {bank[31:16], word[15:0]}:  bank=0→A, 1→B, 2→N
//   wdata_i  — data word to write
//   we_i     — write strobe (pulsed)
//
// Standard compute (triggered by start_i after config):
//   start_i → runs Montgomery compute → result in rd_o + done_o
//   Legacy mode: start_i also loads rs1_i→A[0], rs2_i→B[0] (simple operands)

module hwx_mont_adapter #(
    parameter int WORD_WIDTH = 32,
    parameter int NUM_WORDS  = 4,
    parameter int R          = 1024,
    parameter int N          = 997,
    parameter int N_INV_MOD_N = 493
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     stall_i,
    // Standard HWExplore
    input  logic                     start_i,
    input  logic [WORD_WIDTH-1:0]    rs1_i,
    input  logic [WORD_WIDTH-1:0]    rs2_i,
    // Stateful control
    input  logic [WORD_WIDTH-1:0]    addr_i,
    input  logic [WORD_WIDTH-1:0]    wdata_i,
    input  logic                     we_i,
    // Outputs
    output logic [WORD_WIDTH-1:0]    rd_o,
    output logic                     done_o,
    // Dummy Scratchpad Port B (unused in this adapter since we use local mem)
    output logic [31:0]              sp_addr_o,
    output logic [31:0]              sp_wdata_o,
    output logic                     sp_we_o,
    input  logic [31:0]              sp_rdata_i
);
    assign sp_addr_o  = '0;
    assign sp_wdata_o = '0;
    assign sp_we_o    = 1'b0;

    // Local register files
    logic [WORD_WIDTH-1:0] mem_A [NUM_WORDS-1:0];
    logic [WORD_WIDTH-1:0] mem_B [NUM_WORDS-1:0];
    logic [WORD_WIDTH-1:0] mem_N [NUM_WORDS-1:0];
    logic [WORD_WIDTH-1:0] mem_T [NUM_WORDS:0];

    // Montgomery interface wires
    logic [$clog2(NUM_WORDS)-1:0]    mont_addr_A;
    logic [WORD_WIDTH-1:0]           mont_data_A;
    logic [$clog2(NUM_WORDS)-1:0]    mont_addr_B;
    logic [WORD_WIDTH-1:0]           mont_data_B;
    logic [$clog2(NUM_WORDS)-1:0]    mont_addr_N;
    logic [WORD_WIDTH-1:0]           mont_data_N;
    logic [$clog2(NUM_WORDS+1)-1:0]  mont_addr_T;
    logic [WORD_WIDTH-1:0]           mont_read_T;
    logic [WORD_WIDTH-1:0]           mont_write_T;
    logic                            mont_we_T;
    logic                            mont_start;
    logic                            mont_done;

    // Decode stateful address
    wire [15:0] s_bank   = addr_i[31:16];
    wire [15:0] s_word   = addr_i[$clog2(NUM_WORDS)-1:0];

    // Combined write/load logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < NUM_WORDS; i++) begin
                mem_A[i] <= '0;
                mem_B[i] <= '0;
                mem_N[i] <= '0;
            end
            for (int i = 0; i <= NUM_WORDS; i++) begin
                mem_T[i] <= '0;
            end
        end else if (!stall_i) begin
            // Stateful write (CMD_WRITE_DATA)
            if (we_i && s_bank == 16'd0 && s_word < NUM_WORDS)
                mem_A[s_word] <= wdata_i;
            if (we_i && s_bank == 16'd1 && s_word < NUM_WORDS)
                mem_B[s_word] <= wdata_i;
            if (we_i && s_bank == 16'd2 && s_word < NUM_WORDS)
                mem_N[s_word] <= wdata_i;

            // Legacy mode: on start, load rs1→A[0], rs2→B[0]
            if (start_i) begin
                mem_A[0] <= rs1_i;
                mem_B[0] <= rs2_i;
            end

            // Montgomery write-back
            if (mont_we_T) begin
                mem_T[mont_addr_T] <= mont_write_T;
            end
        end
    end

    // Connect Montgomery memory ports to local arrays
    assign mont_data_A = mem_A[mont_addr_A];
    assign mont_data_B = mem_B[mont_addr_B];
    assign mont_data_N = mem_N[mont_addr_N];
    assign mont_read_T = mem_T[mont_addr_T];

    // Instantiate Montgomery multiplier
    hwx_montgomery_multiplier #(
        .WORD_WIDTH   (WORD_WIDTH),
        .NUM_WORDS    (NUM_WORDS),
        .R            (R),
        .N            (N),
        .N_INV_MOD_N  (N_INV_MOD_N)
    ) u_mont (
        .clk      (clk_i),
        .rst_n    (rst_ni),
        .stall_i  (stall_i),
        .start    (mont_start),
        .done_0   (mont_done),
        .addr_A   (mont_addr_A),
        .data_A   (mont_data_A),
        .addr_B   (mont_addr_B),
        .data_B   (mont_data_B),
        .addr_N   (mont_addr_N),
        .data_N   (mont_data_N),
        .addr_T   (mont_addr_T),
        .read_T   (mont_read_T),
        .write_T  (mont_write_T),
        .we_T     (mont_we_T)
    );

    // Start / done handshake
    logic running_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            running_q <= 1'b0;
            mont_start <= 1'b0;
            done_o     <= 1'b0;
            rd_o       <= '0;
        end else if (!stall_i) begin
            done_o     <= 1'b0;
            mont_start <= 1'b0;

            if (start_i && !running_q) begin
                mont_start <= 1'b1;
                running_q  <= 1'b1;
            end

            if (mont_done && running_q) begin
                running_q <= 1'b0;
                rd_o      <= mem_T[0];  // result in T[0]
                done_o    <= 1'b1;
            end
        end
    end

endmodule