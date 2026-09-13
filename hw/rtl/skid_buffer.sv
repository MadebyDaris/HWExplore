module hwx_skid_buffer #(
    parameter int DATA_WIDTH = 32,
    parameter int BUFFER_DEPTH = 4
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,

    // Slave interface (upstream)
    input  logic                     s_valid,
    output logic                     s_ready,
    input  logic [DATA_WIDTH-1:0]    s_data,

    // Master interface (downstream)
    output logic                     m_valid,
    input  logic                     m_ready,
    output logic [DATA_WIDTH-1:0]    m_data
);

    logic [DATA_WIDTH-1:0] buffer [BUFFER_DEPTH-1:0];
    logic [$clog2(BUFFER_DEPTH):0] head, tail;
    logic [$clog2(BUFFER_DEPTH):0] count;

    assign m_valid = (count > 0);
    assign m_data  = buffer[head];
    assign s_ready = (count < BUFFER_DEPTH);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            head  <= 0;
            tail  <= 0;
            count <= 0;
        end else begin
            if (s_valid && s_ready) begin
                buffer[tail] <= s_data;
                tail <= (tail + 1) % BUFFER_DEPTH;
            end

            if (m_valid && m_ready) begin
                head <= (head + 1) % BUFFER_DEPTH;
            end

            unique case ({s_valid && s_ready, m_valid && m_ready})
                2'b10:   count <= count + 1;
                2'b01:   count <= count - 1;
                default: count <= count;
            endcase
        end
    end

endmodule