module hwx_axi_lite_master #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    // Internal Request Interface
    input  logic                     req_valid_i,
    input  logic                     req_we_i,
    input  logic [ADDR_WIDTH-1:0]    req_addr_i,
    input  logic [DATA_WIDTH-1:0]    req_wdata_i,
    output logic                     req_ready_o,

    // Internal Response Interface
    output logic                     resp_valid_o,
    output logic [DATA_WIDTH-1:0]    resp_rdata_o,
    input  logic                     resp_ready_i,

    // AXI Lite interface
    // Write address channel
    output logic [ADDR_WIDTH-1:0]    axi_awaddr_o,
    output logic                     axi_awvalid_o,
    input  logic                     axi_awready_i,

    // Read address channel
    output logic [ADDR_WIDTH-1:0]    axi_araddr_o,
    output logic                     axi_arvalid_o,
    input  logic                     axi_arready_i,
    // ARPROT, AWPROT, WSTRB, BRESP, RRESP are not used in this implementation

    // Write data channel
    output logic [DATA_WIDTH-1:0]    axi_wdata_o,
    output logic                     axi_wvalid_o,
    input  logic                     axi_wready_i,

    // Read Data channel
    input  logic [DATA_WIDTH-1:0]    axi_rdata_i,
    input  logic                     axi_rresp_i,
    input  logic                     axi_rvalid_i,
    output logic                     axi_rready_o,

    // Write response channel
    input  logic                     axi_bresp_i,
    input  logic                     axi_bvalid_i,
    output logic                     axi_bready_o
);

    logic skid_req_valid, skid_req_ready;
    logic skid_req_we;
    logic [ADDR_WIDTH-1:0] skid_req_addr;
    logic [DATA_WIDTH-1:0] skid_req_wdata;

    hwx_skid_buffer #(
        .DATA_WIDTH(1 + ADDR_WIDTH + DATA_WIDTH),
        .BUFFER_DEPTH(2)
    ) req_skid (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .s_valid (req_valid_i),
        .s_ready (req_ready_o),
        .s_data  ({req_we_i, req_addr_i, req_wdata_i}),
        .m_valid (skid_req_valid),
        .m_ready (skid_req_ready),
        .m_data  ({skid_req_we, skid_req_addr, skid_req_wdata})
    );

    logic skid_resp_valid, skid_resp_ready;
    logic [DATA_WIDTH-1:0] skid_resp_data;

    hwx_skid_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .BUFFER_DEPTH(2)
    ) resp_skid (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .stall_i (1'b0),
        .s_valid (skid_resp_valid),
        .s_ready (skid_resp_ready),
        .s_data  (skid_resp_data),
        .m_valid (resp_valid_o),
        .m_ready (resp_ready_i),
        .m_data  (resp_rdata_o)
    );

    typedef enum logic [2:0] {
        IDLE,
        WRITE_ADDR_DATA,
        WRITE_RESP,
        READ_ADDR,
        READ_DATA
    } state_t;

    state_t state, next_state;
    logic aw_done, next_aw_done;
    logic w_done, next_w_done;

    assign axi_awaddr_o = skid_req_addr;
    assign axi_wdata_o  = skid_req_wdata;
    assign axi_araddr_o = skid_req_addr;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state   <= IDLE;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
        end else begin
            state   <= next_state;
            aw_done <= next_aw_done;
            w_done  <= next_w_done;
        end
    end

    always_comb begin
        next_state   = state;
        next_aw_done = aw_done;
        next_w_done  = w_done;

        axi_awvalid_o = 1'b0;
        axi_wvalid_o  = 1'b0;
        axi_bready_o  = 1'b0;
        axi_arvalid_o = 1'b0;
        axi_rready_o  = 1'b0;

        skid_req_ready  = 1'b0;
        skid_resp_valid = 1'b0;
        skid_resp_data  = '0;

        case (state)
            IDLE: begin
                next_aw_done = 1'b0;
                next_w_done  = 1'b0;
                if (skid_req_valid) begin
                    if (skid_req_we) begin
                        next_state = WRITE_ADDR_DATA;
                    end else begin
                        next_state = READ_ADDR;
                    end
                end
            end

            WRITE_ADDR_DATA: begin
                axi_awvalid_o = ~aw_done;
                axi_wvalid_o  = ~w_done;

                if (axi_awvalid_o && axi_awready_i) begin
                    next_aw_done = 1'b1;
                end
                if (axi_wvalid_o && axi_wready_i) begin
                    next_w_done  = 1'b1;
                end

                if ((aw_done || (axi_awvalid_o && axi_awready_i)) &&
                    (w_done  || (axi_wvalid_o  && axi_wready_i))) begin
                    next_state = WRITE_RESP;
                end
            end

            WRITE_RESP: begin
                axi_bready_o = skid_resp_ready;
                if (axi_bvalid_i && axi_bready_o) begin
                    skid_resp_valid = 1'b1;
                    skid_resp_data  = '0; 
                    skid_req_ready  = 1'b1; 
                    next_state      = IDLE;
                end
            end

            READ_ADDR: begin
                axi_arvalid_o = 1'b1;
                if (axi_arvalid_o && axi_arready_i) begin
                    next_state = READ_DATA;
                end
            end

            READ_DATA: begin
                axi_rready_o = skid_resp_ready;
                if (axi_rvalid_i && axi_rready_o) begin
                    skid_resp_valid = 1'b1;
                    skid_resp_data  = axi_rdata_i;
                    skid_req_ready  = 1'b1;
                    next_state      = IDLE;
                end
            end

            default: next_state = IDLE;
        endcase
    end

endmodule