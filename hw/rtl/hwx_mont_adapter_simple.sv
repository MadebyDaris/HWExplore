module hwx_mont_adapter_simple (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        stall_i,
    input  logic        start_i,
    input  logic [31:0] rs1_i,
    input  logic [31:0] rs2_i,
    
    // Config from mux
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic        we_i,

    output logic [31:0] rd_o,
    output logic        done_o,

    // Scratchpad Port B
    output logic [15:0] sp_addr_o,
    output logic        sp_we_o,
    output logic [31:0] sp_wdata_o,
    input  logic [31:0] sp_rdata_i
);

    typedef enum logic [1:0] {
        IDLE,
        READ,
        WRITE,
        DONE
    } state_t;

    state_t state_q, state_d;
    logic [15:0] cur_addr_q, cur_addr_d;
    logic [31:0] data_q, data_d;

    assign sp_addr_o  = cur_addr_q;
    assign sp_wdata_o = data_q; // Dummy logic: just write it back or use wdata_i
    assign sp_we_o    = (state_q == WRITE);
    assign done_o     = (state_q == DONE);
    assign rd_o       = data_q;

    always_comb begin
        state_d    = state_q;
        cur_addr_d = cur_addr_q;
        data_d     = data_q;

        case (state_q)
            IDLE: begin
                if (start_i) begin
                    cur_addr_d = addr_i[15:0];
                    state_d    = READ;
                end
            end
            READ: begin
                // In a real datapath, we'd wait for read latency and process data.
                state_d = WRITE;
            end
            WRITE: begin
                data_d  = sp_rdata_i; // latching the read result
                state_d = DONE;
            end
            DONE: begin
                state_d = IDLE;
            end
            default: state_d = IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q    <= IDLE;
            cur_addr_q <= '0;
            data_q     <= '0;
        end else if (!stall_i) begin
            state_q    <= state_d;
            cur_addr_q <= cur_addr_d;
            data_q     <= data_d;
        end
    end

endmodule
