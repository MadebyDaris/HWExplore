// HWExplore Implementation of the Montgomery Multiplier algorithm
// calculates (a * b * R^-1) mod n, where R = 2^(k*LANES) and k is the number of bits per lane

module hwx_montgomery_multiplier #(
    parameter WORD_WIDTH = 32,
    parameter NUM_WORDS = 4,
    parameter int R = 1024,
    parameter int N = 997,

    parameter int MONT_CONV = (R * R) % N,
    parameter int N_INV_MOD_N = 493
)(
    input logic clk,
    input logic rst_n,
    input logic stall_i,
    input logic start,
    output logic done_0,

    output reg  [$clog2(NUM_WORDS)-1:0] addr_A,
    input  wire [WORD_WIDTH-1:0]        data_A,
    
    output reg  [$clog2(NUM_WORDS)-1:0] addr_B,
    input  wire [WORD_WIDTH-1:0]        data_B,

    output reg  [$clog2(NUM_WORDS)-1:0] addr_N,
    input  wire [WORD_WIDTH-1:0]        data_N,

    output reg  [$clog2(NUM_WORDS+1)-1:0] addr_T, // Needs extra bits for carries
    input  wire [WORD_WIDTH-1:0]          read_T,

    output reg  [WORD_WIDTH-1:0]          write_T,
    output reg                            we_T
);

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_LOAD_B_ADDR,
        ST_LOAD_B_WAIT,
        ST_COMPUTE_M_ADDR,
        ST_COMPUTE_M_WAIT,
        ST_INNER_LOOP_ADDR,
        ST_INNER_LOOP_SHIFT,
        ST_FLUSH_CARRIES_READ_ADDR,
        ST_FLUSH_CARRIES_READ_WAIT,
        ST_FLUSH_CARRIES_0,
        ST_FLUSH_CARRIES_1,
        ST_FINAL_REDUCE_INIT,
        ST_FINAL_REDUCE_COMPARE_ADDR,
        ST_FINAL_REDUCE_COMPARE_WAIT,
        ST_FINAL_REDUCE_SUB_ADDR,
        ST_FINAL_REDUCE_SUB_WAIT,
        ST_FINAL_REDUCE_CLEAR_TK,
        ST_DONE
    } state_t;

    state_t state, next_state;

    logic [$clog2(NUM_WORDS)-1:0] i_reg, i_next;
    logic [$clog2(NUM_WORDS+1)-1:0] j_reg, j_next;

    logic [WORD_WIDTH-1:0] reg_b_i, reg_b_i_next;
    logic [WORD_WIDTH-1:0] reg_m, reg_m_next;

    logic [WORD_WIDTH-1:0] carry_A, carry_A_next;
    logic [WORD_WIDTH-1:0] carry_N, carry_N_next;
    logic final_t_k, final_t_k_next;
    
    logic borrow, borrow_next;

    logic [63:0] P, Q;
    
    assign P = {32'd0, read_T} + ( {32'd0, data_A} * {32'd0, reg_b_i} ) + {32'd0, carry_A};
    assign Q = {32'd0, P[31:0]} + ( {32'd0, data_N} * {32'd0, reg_m} ) + {32'd0, carry_N};

    logic [63:0] m_mult;
    logic [31:0] P_m;
    assign P_m = read_T + data_A * reg_b_i;
    assign m_mult = {32'd0, P_m} * {32'd0, N_INV_MOD_N};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            i_reg <= 0;
            j_reg <= 0;
            reg_b_i <= 0;
            reg_m <= 0;
            carry_A <= 0;
            carry_N <= 0;
            final_t_k <= 0;
            borrow <= 0;
        end else if (!stall_i) begin
            state <= next_state;
            i_reg <= i_next;
            j_reg <= j_next;
            reg_b_i <= reg_b_i_next;
            reg_m <= reg_m_next;
            carry_A <= carry_A_next;
            carry_N <= carry_N_next;
            final_t_k <= final_t_k_next;
            borrow <= borrow_next;
        end
    end

    logic [32:0] final_sum;
    assign final_sum = carry_A + carry_N + read_T;

    logic [32:0] sub_res;
    assign sub_res = {1'b0, read_T} - {1'b0, data_N} - {32'd0, borrow};

    always_comb begin
        next_state = state;
        i_next = i_reg;
        j_next = j_reg;
        reg_b_i_next = reg_b_i;
        reg_m_next = reg_m;
        carry_A_next = carry_A;
        carry_N_next = carry_N;
        final_t_k_next = final_t_k;
        borrow_next = borrow;

        addr_A = 0;
        addr_B = 0;
        addr_N = 0;
        addr_T = 0;
        write_T = 0;
        we_T = 0;
        done_0 = 0;

        case (state)
            ST_IDLE: begin
                if (start) begin
                    i_next = 0;
                    next_state = ST_LOAD_B_ADDR;
                end
            end

            ST_LOAD_B_ADDR: begin
                addr_B = i_reg;
                next_state = ST_LOAD_B_WAIT;
            end

            ST_LOAD_B_WAIT: begin
                reg_b_i_next = data_B;
                next_state = ST_COMPUTE_M_ADDR;
            end

            ST_COMPUTE_M_ADDR: begin
                addr_A = 0;
                addr_T = 0;
                next_state = ST_COMPUTE_M_WAIT;
            end

            ST_COMPUTE_M_WAIT: begin
                reg_m_next = m_mult[31:0];
                j_next = 0;
                carry_A_next = 0;
                carry_N_next = 0;
                next_state = ST_INNER_LOOP_ADDR;
            end

            ST_INNER_LOOP_ADDR: begin
                addr_A = j_reg[$clog2(NUM_WORDS)-1:0];
                addr_N = j_reg[$clog2(NUM_WORDS)-1:0];
                addr_T = j_reg;
                next_state = ST_INNER_LOOP_SHIFT;
            end

            ST_INNER_LOOP_SHIFT: begin
                carry_A_next = P[63:32];
                carry_N_next = Q[63:32];
                if (j_reg > 0) begin
                    addr_T = j_reg - 1;
                    we_T = 1;
                    write_T = Q[31:0];
                end
                
                if (j_reg == NUM_WORDS - 1) begin
                    next_state = ST_FLUSH_CARRIES_READ_ADDR;
                end else begin
                    j_next = j_reg + 1;
                    next_state = ST_INNER_LOOP_ADDR;
                end
            end

            ST_FLUSH_CARRIES_READ_ADDR: begin
                addr_T = NUM_WORDS;
                next_state = ST_FLUSH_CARRIES_READ_WAIT;
            end

            ST_FLUSH_CARRIES_READ_WAIT: begin
                next_state = ST_FLUSH_CARRIES_0;
            end

            ST_FLUSH_CARRIES_0: begin
                addr_T = NUM_WORDS - 1;
                we_T = 1;
                write_T = final_sum[31:0];
                
                carry_A_next = {31'd0, final_sum[32]};
                next_state = ST_FLUSH_CARRIES_1;
            end

            ST_FLUSH_CARRIES_1: begin
                addr_T = NUM_WORDS;
                we_T = 1;
                write_T = carry_A;
                
                if (i_reg == NUM_WORDS - 1) begin
                    final_t_k_next = carry_A[0];
                    next_state = ST_FINAL_REDUCE_INIT;
                end else begin
                    i_next = i_reg + 1;
                    next_state = ST_LOAD_B_ADDR;
                end
            end

            ST_FINAL_REDUCE_INIT: begin
                if (final_t_k) begin
                    j_next = 0;
                    borrow_next = 0;
                    next_state = ST_FINAL_REDUCE_SUB_ADDR;
                end else begin
                    j_next = NUM_WORDS - 1;
                    next_state = ST_FINAL_REDUCE_COMPARE_ADDR;
                end
            end

            ST_FINAL_REDUCE_COMPARE_ADDR: begin
                addr_T = j_reg;
                addr_N = j_reg[$clog2(NUM_WORDS)-1:0];
                next_state = ST_FINAL_REDUCE_COMPARE_WAIT;
            end

            ST_FINAL_REDUCE_COMPARE_WAIT: begin
                if (read_T > data_N) begin
                    j_next = 0;
                    borrow_next = 0;
                    next_state = ST_FINAL_REDUCE_SUB_ADDR;
                end else if (read_T < data_N) begin
                    next_state = ST_DONE;
                end else begin
                    if (j_reg == 0) begin
                        j_next = 0;
                        borrow_next = 0;
                        next_state = ST_FINAL_REDUCE_SUB_ADDR;
                    end else begin
                        j_next = j_reg - 1;
                        next_state = ST_FINAL_REDUCE_COMPARE_ADDR;
                    end
                end
            end

            ST_FINAL_REDUCE_SUB_ADDR: begin
                addr_T = j_reg;
                addr_N = j_reg[$clog2(NUM_WORDS)-1:0];
                next_state = ST_FINAL_REDUCE_SUB_WAIT;
            end

            ST_FINAL_REDUCE_SUB_WAIT: begin
                addr_T = j_reg;
                we_T = 1;
                write_T = sub_res[31:0];
                borrow_next = sub_res[32];
                
                if (j_reg == NUM_WORDS - 1) begin
                    next_state = ST_FINAL_REDUCE_CLEAR_TK;
                end else begin
                    j_next = j_reg + 1;
                    next_state = ST_FINAL_REDUCE_SUB_ADDR;
                end
            end

            ST_FINAL_REDUCE_CLEAR_TK: begin
                addr_T = NUM_WORDS;
                we_T = 1;
                write_T = 0;
                next_state = ST_DONE;
            end

            ST_DONE: begin
                done_0 = 1;
                next_state = ST_IDLE;
            end
            
            default: next_state = ST_IDLE;
        endcase
    end
endmodule