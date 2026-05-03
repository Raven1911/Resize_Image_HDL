`timescale 1ns / 1ps

module resize_maxpooling #(
    parameter ADDR_WIDTH_BASE = 24,

    // ============================================================
    // Input frame buffer size
    // ============================================================
    parameter IN_W      = 640,
    parameter IN_H      = 480,

    // ============================================================
    // Output fixed size 224x224
    // ============================================================
    parameter OUT_SIZE  = 224,

    // ============================================================
    // 640x480 -> 224x224 with padding
    // real image area = 224x168
    // padding top     = 28
    // padding bottom  = 28
    // ============================================================
    parameter SCALED_H  = 168,
    parameter PAD_TOP   = 28,

    // ============================================================
    // Fixed-point Q16.16
    // X_STEP = floor((640 << 16) / 224) = 187245
    // Y_STEP = floor((480 << 16) / 168) = 187245
    // ============================================================
    parameter FP        = 16,
    parameter X_STEP    = 32'd187245,
    parameter Y_STEP    = 32'd187245
)(
    // ============================================================
    // System
    // ============================================================
    input                               clk_i,
    input                               resetn_i,

    // ============================================================
    // Quantization config
    //
    // Formula per channel:
    //
    //   q = clamp_int8(
    //          round((pixel_u8 * scale_inf_mult_reg)
    //                / 2^scale_inf_mult_shift_reg)
    //          + zp_i
    //       )
    //
    // For simple uint8 -> int8:
    //
    //   q = pixel_u8 - 128
    //
    // use:
    //
    //   scale_inf_mult_reg       = 32'sd1
    //   scale_inf_mult_shift_reg = 6'd0
    //   zp_i                     = -8'sd128
    // ============================================================
    input   signed [31:0]              scale_inf_mult_reg,
    input          [5:0]               scale_inf_mult_shift_reg,
    input   signed [7:0]               zp_i,

    // ============================================================
    // DMA handshake
    // 1 handshake = process 1 output row.
    // cal_addr_base_i is used only to detect frame start when == 0.
    // ============================================================
    input   [ADDR_WIDTH_BASE-1:0]       cal_addr_base_i,
    input                               cal_valid_i,
    output                              cal_ready_o,

    // ============================================================
    // Frame buffer read interface
    // latency = 1 clock
    // ============================================================
    output  [ADDR_WIDTH_BASE-1:0]       fb_addr_o,
    input   [15:0]                      fb_pixel_data_i,

    // ============================================================
    // FIFO output
    //
    // 3 output channels are valid at the same cycle:
    //
    //   ff_r_pixel_data_o -> FIFO R
    //   ff_g_pixel_data_o -> FIFO G
    //   ff_b_pixel_data_o -> FIFO B
    //
    // Use the same ff_wr_rgb_buf_o for all 3 FIFOs.
    //
    // ff_tlast_pixel_o is asserted with the final pixel of a row,
    // in the same cycle as the 3 quantized channel outputs.
    // ============================================================
    output                              ff_wr_rgb_buf_o,
    output                              ff_tlast_pixel_o,
    output  signed [7:0]                ff_r_pixel_data_o,
    output  signed [7:0]                ff_g_pixel_data_o,
    output  signed [7:0]                ff_b_pixel_data_o
);

    // ============================================================
    // Local constants
    // ============================================================

    localparam [7:0] OUT_LAST       = OUT_SIZE - 1;          // 223
    localparam [7:0] PAD_TOP_8      = PAD_TOP;               // 28
    localparam [7:0] PAD_END_8      = PAD_TOP + SCALED_H;    // 196

    localparam [9:0] IN_W_LAST      = IN_W - 1;              // 639
    localparam [8:0] IN_H_LAST      = IN_H - 1;              // 479

    // ============================================================
    // FSM states
    // ============================================================

    localparam S_IDLE        = 4'd0;
    localparam S_ROW_SETUP   = 4'd1;
    localparam S_ROW_Y_CALC  = 4'd2;
    localparam S_PIXEL_SETUP = 4'd3;
    localparam S_STREAM      = 4'd4;
    localparam S_Q_FEED      = 4'd5;
    localparam S_PAD_FEED    = 4'd6;
    localparam S_ROW_DRAIN   = 4'd7;
    localparam S_ROW_DONE    = 4'd8;

    reg [3:0] state_reg;
    reg [3:0] state_next;

    // ============================================================
    // Output registers
    // ============================================================

    reg [ADDR_WIDTH_BASE-1:0] fb_addr_comb;

    reg        ff_wr_rgb_buf_reg;
    reg        ff_wr_rgb_buf_next;

    reg        ff_tlast_pixel_reg;
    reg        ff_tlast_pixel_next;

    reg signed [7:0] ff_r_pixel_data_reg;
    reg signed [7:0] ff_r_pixel_data_next;

    reg signed [7:0] ff_g_pixel_data_reg;
    reg signed [7:0] ff_g_pixel_data_next;

    reg signed [7:0] ff_b_pixel_data_reg;
    reg signed [7:0] ff_b_pixel_data_next;

    assign fb_addr_o          = fb_addr_comb;
    assign ff_wr_rgb_buf_o    = ff_wr_rgb_buf_reg;
    assign ff_tlast_pixel_o   = ff_tlast_pixel_reg;
    assign ff_r_pixel_data_o  = ff_r_pixel_data_reg;
    assign ff_g_pixel_data_o  = ff_g_pixel_data_reg;
    assign ff_b_pixel_data_o  = ff_b_pixel_data_reg;

    // ============================================================
    // DMA handshake
    // ============================================================

    assign cal_ready_o = (state_reg == S_IDLE);

    wire fire;
    assign fire = cal_valid_i && cal_ready_o;

    // ============================================================
    // Row / pixel counters
    // ============================================================

    reg [7:0] row_y_reg;
    reg [7:0] row_y_next;

    reg [7:0] current_row_y_reg;
    reg [7:0] current_row_y_next;

    reg [7:0] out_x_reg;
    reg [7:0] out_x_next;

    wire row_padding;
    assign row_padding =
        (current_row_y_reg < PAD_TOP_8) ||
        (current_row_y_reg >= PAD_END_8);

    wire row_real_image;
    assign row_real_image =
        (current_row_y_reg >= PAD_TOP_8) &&
        (current_row_y_reg < PAD_END_8);

    // ============================================================
    // Q16.16 accumulators
    //
    // Timing optimization:
    //   x_acc += X_STEP per output pixel
    //   y_acc += Y_STEP per real output row
    //
    // Avoid runtime multipliers in resize mapping.
    // ============================================================

    reg [31:0] x_acc_reg;
    reg [31:0] x_acc_next;

    reg [31:0] y_acc_reg;
    reg [31:0] y_acc_next;

    wire [31:0] x_acc_plus_step;
    wire [31:0] y_acc_plus_step;

    assign x_acc_plus_step = x_acc_reg + X_STEP;
    assign y_acc_plus_step = y_acc_reg + Y_STEP;

    // ============================================================
    // Y mapping from accumulator
    // ============================================================

    wire [8:0] calc_src_y0;
    wire [8:0] calc_src_y1_raw;

    assign calc_src_y0     = y_acc_reg[FP+8:FP];
    assign calc_src_y1_raw = y_acc_plus_step[FP+8:FP];

    reg [8:0] row_src_y0_reg;
    reg [8:0] row_src_y0_next;

    reg [8:0] row_src_y1_reg;
    reg [8:0] row_src_y1_next;

    // y * 640 = y * 512 + y * 128
    wire [18:0] calc_y0_base;
    assign calc_y0_base = (calc_src_y0 << 9) + (calc_src_y0 << 7);

    reg [18:0] row_src_y0_base_reg;
    reg [18:0] row_src_y0_base_next;

    // ============================================================
    // X mapping from accumulator
    // ============================================================

    wire [9:0] calc_src_x0;
    wire [9:0] calc_src_x1_raw;

    assign calc_src_x0     = x_acc_reg[FP+9:FP];
    assign calc_src_x1_raw = x_acc_plus_step[FP+9:FP];

    reg [9:0] src_x0_reg;
    reg [9:0] src_x0_next;

    reg [9:0] src_x1_reg;
    reg [9:0] src_x1_next;

    // ============================================================
    // Issue side
    // ============================================================

    reg        issue_active_reg;
    reg        issue_active_next;

    reg [9:0] issue_x_reg;
    reg [9:0] issue_x_next;

    reg [8:0] issue_y_reg;
    reg [8:0] issue_y_next;

    reg [18:0] issue_row_base_reg;
    reg [18:0] issue_row_base_next;

    wire [18:0] issue_addr;
    wire        issue_last;

    assign issue_addr = issue_row_base_reg + issue_x_reg;

    assign issue_last =
        (issue_x_reg == src_x1_reg) &&
        (issue_y_reg == row_src_y1_reg);

    // ============================================================
    // Return side
    // frame buffer latency = 1 clock
    // ============================================================

    reg rd_valid_reg;
    reg rd_valid_next;

    reg rd_last_reg;
    reg rd_last_next;

    // ============================================================
    // RGB565 max pooling
    // ============================================================

    reg [4:0] max_r_reg;
    reg [4:0] max_r_next;

    reg [5:0] max_g_reg;
    reg [5:0] max_g_next;

    reg [4:0] max_b_reg;
    reg [4:0] max_b_next;

    wire [4:0] pix_r;
    wire [5:0] pix_g;
    wire [4:0] pix_b;

    assign pix_r = fb_pixel_data_i[15:11];
    assign pix_g = fb_pixel_data_i[10:5];
    assign pix_b = fb_pixel_data_i[4:0];

    wire [4:0] next_max_r;
    wire [5:0] next_max_g;
    wire [4:0] next_max_b;

    assign next_max_r = (pix_r > max_r_reg) ? pix_r : max_r_reg;
    assign next_max_g = (pix_g > max_g_reg) ? pix_g : max_g_reg;
    assign next_max_b = (pix_b > max_b_reg) ? pix_b : max_b_reg;

    // RGB565 result before quantization
    reg [15:0] pixel_result_reg;
    reg [15:0] pixel_result_next;

    // Expand RGB565 -> RGB888 channels
    wire [4:0] result_r5;
    wire [5:0] result_g6;
    wire [4:0] result_b5;

    wire [7:0] result_r8;
    wire [7:0] result_g8;
    wire [7:0] result_b8;

    assign result_r5 = pixel_result_reg[15:11];
    assign result_g6 = pixel_result_reg[10:5];
    assign result_b5 = pixel_result_reg[4:0];

    assign result_r8 = {result_r5, result_r5[4:2]};
    assign result_g8 = {result_g6, result_g6[5:4]};
    assign result_b8 = {result_b5, result_b5[4:2]};

    // ============================================================
    // Quantizer input control
    // One q_in_valid carries R/G/B simultaneously.
    // ============================================================

    reg        q_in_valid;
    reg [7:0]  q_in_r8;
    reg [7:0]  q_in_g8;
    reg [7:0]  q_in_b8;
    reg        q_in_last;

    // ============================================================
    // Parallel quantizer pipeline for R/G/B
    //
    // 5 stages:
    //   1. multiply
    //   2. add rounding value
    //   3. arithmetic shift
    //   4. add zero-point
    //   5. clamp to signed int8
    //
    // Since FIFO has no full/ready, this pipeline has no backpressure.
    // ============================================================

    reg [4:0] q_valid_reg;
    reg [4:0] q_valid_next;

    reg [4:0] q_last_reg;
    reg [4:0] q_last_next;

    // Stage registers for R
    reg signed [40:0] qr_stage1_reg, qr_stage1_next;
    reg signed [40:0] qr_stage2_reg, qr_stage2_next;
    reg signed [40:0] qr_stage3_reg, qr_stage3_next;
    reg signed [40:0] qr_stage4_reg, qr_stage4_next;
    reg signed [7:0]  qr_stage5_reg, qr_stage5_next;

    // Stage registers for G
    reg signed [40:0] qg_stage1_reg, qg_stage1_next;
    reg signed [40:0] qg_stage2_reg, qg_stage2_next;
    reg signed [40:0] qg_stage3_reg, qg_stage3_next;
    reg signed [40:0] qg_stage4_reg, qg_stage4_next;
    reg signed [7:0]  qg_stage5_reg, qg_stage5_next;

    // Stage registers for B
    reg signed [40:0] qb_stage1_reg, qb_stage1_next;
    reg signed [40:0] qb_stage2_reg, qb_stage2_next;
    reg signed [40:0] qb_stage3_reg, qb_stage3_next;
    reg signed [40:0] qb_stage4_reg, qb_stage4_next;
    reg signed [7:0]  qb_stage5_reg, qb_stage5_next;

    wire signed [8:0] q_r_pixel_s;
    wire signed [8:0] q_g_pixel_s;
    wire signed [8:0] q_b_pixel_s;

    assign q_r_pixel_s = $signed({1'b0, q_in_r8});
    assign q_g_pixel_s = $signed({1'b0, q_in_g8});
    assign q_b_pixel_s = $signed({1'b0, q_in_b8});

    wire signed [40:0] qr_stage1_d;
    wire signed [40:0] qg_stage1_d;
    wire signed [40:0] qb_stage1_d;

    assign qr_stage1_d = q_r_pixel_s * scale_inf_mult_reg;
    assign qg_stage1_d = q_g_pixel_s * scale_inf_mult_reg;
    assign qb_stage1_d = q_b_pixel_s * scale_inf_mult_reg;

    wire signed [40:0] round_value;

    assign round_value =
        (scale_inf_mult_shift_reg != 6'd0) ?
        (41'sd1 <<< (scale_inf_mult_shift_reg - 6'd1)) :
        41'sd0;

    // Stage 2: add round value
    wire signed [40:0] qr_stage2_d;
    wire signed [40:0] qg_stage2_d;
    wire signed [40:0] qb_stage2_d;

    assign qr_stage2_d = qr_stage1_reg + round_value -
                         (((scale_inf_mult_shift_reg != 6'd0) && qr_stage1_reg[40]) ? 41'sd1 : 41'sd0);
    assign qg_stage2_d = qg_stage1_reg + round_value -
                         (((scale_inf_mult_shift_reg != 6'd0) && qg_stage1_reg[40]) ? 41'sd1 : 41'sd0);
    assign qb_stage2_d = qb_stage1_reg + round_value -
                         (((scale_inf_mult_shift_reg != 6'd0) && qb_stage1_reg[40]) ? 41'sd1 : 41'sd0);

    // Stage 3: arithmetic shift
    wire signed [40:0] qr_stage3_d;
    wire signed [40:0] qg_stage3_d;
    wire signed [40:0] qb_stage3_d;

    assign qr_stage3_d =
        (scale_inf_mult_shift_reg != 6'd0) ?
        (qr_stage2_reg >>> scale_inf_mult_shift_reg) :
        qr_stage2_reg;

    assign qg_stage3_d =
        (scale_inf_mult_shift_reg != 6'd0) ?
        (qg_stage2_reg >>> scale_inf_mult_shift_reg) :
        qg_stage2_reg;

    assign qb_stage3_d =
        (scale_inf_mult_shift_reg != 6'd0) ?
        (qb_stage2_reg >>> scale_inf_mult_shift_reg) :
        qb_stage2_reg;

    // Stage 4: add zero point
    wire signed [40:0] qr_stage4_d;
    wire signed [40:0] qg_stage4_d;
    wire signed [40:0] qb_stage4_d;

    assign qr_stage4_d = qr_stage3_reg + {{33{zp_i[7]}}, zp_i};
    assign qg_stage4_d = qg_stage3_reg + {{33{zp_i[7]}}, zp_i};
    assign qb_stage4_d = qb_stage3_reg + {{33{zp_i[7]}}, zp_i};

    // Stage 5: clamp to signed int8 [-128, 127]
    wire signed [7:0] qr_stage5_d;
    wire signed [7:0] qg_stage5_d;
    wire signed [7:0] qb_stage5_d;

    assign qr_stage5_d =
        ((|qr_stage4_reg[40:7]) && !(&qr_stage4_reg[40:7])) ?
            (qr_stage4_reg[40] ? -8'sd128 : 8'sd127) :
            qr_stage4_reg[7:0];

    assign qg_stage5_d =
        ((|qg_stage4_reg[40:7]) && !(&qg_stage4_reg[40:7])) ?
            (qg_stage4_reg[40] ? -8'sd128 : 8'sd127) :
            qg_stage4_reg[7:0];

    assign qb_stage5_d =
        ((|qb_stage4_reg[40:7]) && !(&qb_stage4_reg[40:7])) ?
            (qb_stage4_reg[40] ? -8'sd128 : 8'sd127) :
            qb_stage4_reg[7:0];

    wire q_out_valid;
    wire q_out_last;

    assign q_out_valid = q_valid_reg[4];
    assign q_out_last  = q_last_reg[4];

    // ============================================================
    // Sequential block
    // ============================================================

    always @(posedge clk_i) begin
        if (!resetn_i) begin
            state_reg <= S_IDLE;

            ff_wr_rgb_buf_reg   <= 1'b0;
            ff_tlast_pixel_reg  <= 1'b0;
            ff_r_pixel_data_reg <= 8'sd0;
            ff_g_pixel_data_reg <= 8'sd0;
            ff_b_pixel_data_reg <= 8'sd0;

            row_y_reg           <= 8'd0;
            current_row_y_reg   <= 8'd0;
            out_x_reg           <= 8'd0;

            x_acc_reg           <= 32'd0;
            y_acc_reg           <= 32'd0;

            row_src_y0_reg      <= 9'd0;
            row_src_y1_reg      <= 9'd0;
            row_src_y0_base_reg <= 19'd0;

            src_x0_reg          <= 10'd0;
            src_x1_reg          <= 10'd0;

            issue_active_reg    <= 1'b0;
            issue_x_reg         <= 10'd0;
            issue_y_reg         <= 9'd0;
            issue_row_base_reg  <= 19'd0;

            rd_valid_reg        <= 1'b0;
            rd_last_reg         <= 1'b0;

            max_r_reg           <= 5'd0;
            max_g_reg           <= 6'd0;
            max_b_reg           <= 5'd0;

            pixel_result_reg    <= 16'd0;

            q_valid_reg         <= 5'd0;
            q_last_reg          <= 5'd0;

            qr_stage1_reg       <= 41'sd0;
            qr_stage2_reg       <= 41'sd0;
            qr_stage3_reg       <= 41'sd0;
            qr_stage4_reg       <= 41'sd0;
            qr_stage5_reg       <= 8'sd0;

            qg_stage1_reg       <= 41'sd0;
            qg_stage2_reg       <= 41'sd0;
            qg_stage3_reg       <= 41'sd0;
            qg_stage4_reg       <= 41'sd0;
            qg_stage5_reg       <= 8'sd0;

            qb_stage1_reg       <= 41'sd0;
            qb_stage2_reg       <= 41'sd0;
            qb_stage3_reg       <= 41'sd0;
            qb_stage4_reg       <= 41'sd0;
            qb_stage5_reg       <= 8'sd0;
        end else begin
            state_reg <= state_next;

            ff_wr_rgb_buf_reg   <= ff_wr_rgb_buf_next;
            ff_tlast_pixel_reg  <= ff_tlast_pixel_next;
            ff_r_pixel_data_reg <= ff_r_pixel_data_next;
            ff_g_pixel_data_reg <= ff_g_pixel_data_next;
            ff_b_pixel_data_reg <= ff_b_pixel_data_next;

            row_y_reg           <= row_y_next;
            current_row_y_reg   <= current_row_y_next;
            out_x_reg           <= out_x_next;

            x_acc_reg           <= x_acc_next;
            y_acc_reg           <= y_acc_next;

            row_src_y0_reg      <= row_src_y0_next;
            row_src_y1_reg      <= row_src_y1_next;
            row_src_y0_base_reg <= row_src_y0_base_next;

            src_x0_reg          <= src_x0_next;
            src_x1_reg          <= src_x1_next;

            issue_active_reg    <= issue_active_next;
            issue_x_reg         <= issue_x_next;
            issue_y_reg         <= issue_y_next;
            issue_row_base_reg  <= issue_row_base_next;

            rd_valid_reg        <= rd_valid_next;
            rd_last_reg         <= rd_last_next;

            max_r_reg           <= max_r_next;
            max_g_reg           <= max_g_next;
            max_b_reg           <= max_b_next;

            pixel_result_reg    <= pixel_result_next;

            q_valid_reg         <= q_valid_next;
            q_last_reg          <= q_last_next;

            qr_stage1_reg       <= qr_stage1_next;
            qr_stage2_reg       <= qr_stage2_next;
            qr_stage3_reg       <= qr_stage3_next;
            qr_stage4_reg       <= qr_stage4_next;
            qr_stage5_reg       <= qr_stage5_next;

            qg_stage1_reg       <= qg_stage1_next;
            qg_stage2_reg       <= qg_stage2_next;
            qg_stage3_reg       <= qg_stage3_next;
            qg_stage4_reg       <= qg_stage4_next;
            qg_stage5_reg       <= qg_stage5_next;

            qb_stage1_reg       <= qb_stage1_next;
            qb_stage2_reg       <= qb_stage2_next;
            qb_stage3_reg       <= qb_stage3_next;
            qb_stage4_reg       <= qb_stage4_next;
            qb_stage5_reg       <= qb_stage5_next;
        end
    end

    // ============================================================
    // Combinational block
    // ============================================================

    always @(*) begin
        // ------------------------------------------------------------
        // Default hold
        // ------------------------------------------------------------
        state_next = state_reg;

        fb_addr_comb = {ADDR_WIDTH_BASE{1'b0}};

        // FIFO output is registered pulse
        ff_wr_rgb_buf_next   = 1'b0;
        ff_tlast_pixel_next  = 1'b0;
        ff_r_pixel_data_next = ff_r_pixel_data_reg;
        ff_g_pixel_data_next = ff_g_pixel_data_reg;
        ff_b_pixel_data_next = ff_b_pixel_data_reg;

        row_y_next           = row_y_reg;
        current_row_y_next   = current_row_y_reg;
        out_x_next           = out_x_reg;

        x_acc_next           = x_acc_reg;
        y_acc_next           = y_acc_reg;

        row_src_y0_next      = row_src_y0_reg;
        row_src_y1_next      = row_src_y1_reg;
        row_src_y0_base_next = row_src_y0_base_reg;

        src_x0_next          = src_x0_reg;
        src_x1_next          = src_x1_reg;

        issue_active_next    = issue_active_reg;
        issue_x_next         = issue_x_reg;
        issue_y_next         = issue_y_reg;
        issue_row_base_next  = issue_row_base_reg;

        rd_valid_next        = rd_valid_reg;
        rd_last_next         = rd_last_reg;

        max_r_next           = max_r_reg;
        max_g_next           = max_g_reg;
        max_b_next           = max_b_reg;

        pixel_result_next    = pixel_result_reg;

        // Quantizer input default
        q_in_valid = 1'b0;
        q_in_r8    = 8'd0;
        q_in_g8    = 8'd0;
        q_in_b8    = 8'd0;
        q_in_last  = 1'b0;

        // Quantizer pipeline always advances one stage per clock
        q_valid_next = {q_valid_reg[3:0], q_in_valid};
        q_last_next  = {q_last_reg[3:0],  q_in_last};

        // Quantizer data pipeline
        qr_stage1_next = qr_stage1_d;
        qr_stage2_next = qr_stage2_d;
        qr_stage3_next = qr_stage3_d;
        qr_stage4_next = qr_stage4_d;
        qr_stage5_next = qr_stage5_d;

        qg_stage1_next = qg_stage1_d;
        qg_stage2_next = qg_stage2_d;
        qg_stage3_next = qg_stage3_d;
        qg_stage4_next = qg_stage4_d;
        qg_stage5_next = qg_stage5_d;

        qb_stage1_next = qb_stage1_d;
        qb_stage2_next = qb_stage2_d;
        qb_stage3_next = qb_stage3_d;
        qb_stage4_next = qb_stage4_d;
        qb_stage5_next = qb_stage5_d;

        // Quantizer output to 3 FIFOs.
        // All 3 channels valid together.
        if (q_out_valid) begin
            ff_wr_rgb_buf_next   = 1'b1;
            ff_tlast_pixel_next  = q_out_last;
            ff_r_pixel_data_next = qr_stage5_reg;
            ff_g_pixel_data_next = qg_stage5_reg;
            ff_b_pixel_data_next = qb_stage5_reg;
        end

        case (state_reg)

            // ========================================================
            // Wait for DMA request for one output row
            // ========================================================
            S_IDLE: begin
                issue_active_next = 1'b0;
                rd_valid_next     = 1'b0;
                rd_last_next      = 1'b0;

                if (fire) begin
                    out_x_next = 8'd0;
                    x_acc_next = 32'd0;

                    if (cal_addr_base_i == {ADDR_WIDTH_BASE{1'b0}}) begin
                        current_row_y_next = 8'd0;
                        row_y_next         = 8'd0;
                        y_acc_next         = 32'd0;
                    end else begin
                        current_row_y_next = row_y_reg;
                    end

                    state_next = S_ROW_SETUP;
                end
            end

            // ========================================================
            // Check padding row
            // ========================================================
            S_ROW_SETUP: begin
                if (row_padding) begin
                    // Padding RGB565 = black
                    pixel_result_next = 16'h0000;
                    state_next        = S_PAD_FEED;
                end else begin
                    state_next = S_ROW_Y_CALC;
                end
            end

            // ========================================================
            // Compute source Y window using y_acc
            // ========================================================
            S_ROW_Y_CALC: begin
                row_src_y0_next      = calc_src_y0;
                row_src_y0_base_next = calc_y0_base;

                if (current_row_y_reg == (PAD_END_8 - 8'd1)) begin
                    row_src_y1_next = IN_H_LAST;
                end else if (calc_src_y1_raw == 9'd0) begin
                    row_src_y1_next = 9'd0;
                end else begin
                    row_src_y1_next = calc_src_y1_raw - 9'd1;
                end

                state_next = S_PIXEL_SETUP;
            end

            // ========================================================
            // Compute source X window using x_acc
            // ========================================================
            S_PIXEL_SETUP: begin
                src_x0_next = calc_src_x0;

                if (out_x_reg == OUT_LAST) begin
                    src_x1_next = IN_W_LAST;
                end else if (calc_src_x1_raw == 10'd0) begin
                    src_x1_next = 10'd0;
                end else begin
                    src_x1_next = calc_src_x1_raw - 10'd1;
                end

                // Prepare x accumulator for next output pixel
                x_acc_next = x_acc_plus_step;

                // Setup issue side
                issue_x_next        = calc_src_x0;
                issue_y_next        = row_src_y0_reg;
                issue_row_base_next = row_src_y0_base_reg;
                issue_active_next   = 1'b1;

                // Clear return side
                rd_valid_next = 1'b0;
                rd_last_next  = 1'b0;

                // Clear max accumulator
                max_r_next = 5'd0;
                max_g_next = 6'd0;
                max_b_next = 5'd0;

                state_next = S_STREAM;
            end

            // ========================================================
            // Stream input window from frame buffer
            // ========================================================
            S_STREAM: begin
                // Return side
                if (rd_valid_reg) begin
                    max_r_next = next_max_r;
                    max_g_next = next_max_g;
                    max_b_next = next_max_b;

                    if (rd_last_reg) begin
                        pixel_result_next = {next_max_r, next_max_g, next_max_b};
                        state_next        = S_Q_FEED;
                    end
                end

                // Issue side
                if (issue_active_reg) begin
                    fb_addr_comb = {{(ADDR_WIDTH_BASE-19){1'b0}}, issue_addr};

                    rd_valid_next = 1'b1;
                    rd_last_next  = issue_last;

                    if (issue_last) begin
                        issue_active_next = 1'b0;
                    end else begin
                        if (issue_x_reg < src_x1_reg) begin
                            issue_x_next = issue_x_reg + 10'd1;
                        end else begin
                            issue_x_next        = src_x0_reg;
                            issue_y_next        = issue_y_reg + 9'd1;
                            issue_row_base_next = issue_row_base_reg + IN_W;
                        end
                    end
                end else begin
                    rd_valid_next = 1'b0;
                    rd_last_next  = 1'b0;
                end
            end

            // ========================================================
            // Feed real-image pixel result to parallel quantizer
            // ========================================================
            S_Q_FEED: begin
                q_in_valid = 1'b1;
                q_in_r8    = result_r8;
                q_in_g8    = result_g8;
                q_in_b8    = result_b8;
                q_in_last  = (out_x_reg == OUT_LAST);

                if (out_x_reg == OUT_LAST) begin
                    state_next = S_ROW_DRAIN;
                end else begin
                    out_x_next = out_x_reg + 8'd1;
                    state_next = S_PIXEL_SETUP;
                end
            end

            // ========================================================
            // Padding row: feed black pixels directly to quantizer
            // This can feed 1 pixel per clock.
            // ========================================================
            S_PAD_FEED: begin
                q_in_valid = 1'b1;
                q_in_r8    = 8'd0;
                q_in_g8    = 8'd0;
                q_in_b8    = 8'd0;
                q_in_last  = (out_x_reg == OUT_LAST);

                if (out_x_reg == OUT_LAST) begin
                    state_next = S_ROW_DRAIN;
                end else begin
                    out_x_next = out_x_reg + 8'd1;
                    state_next = S_PAD_FEED;
                end
            end

            // ========================================================
            // Wait until the final quantized pixel of this row
            // leaves the pipeline.
            // ========================================================
            S_ROW_DRAIN: begin
                if (q_out_valid && q_out_last) begin
                    state_next = S_ROW_DONE;
                end
            end

            // ========================================================
            // End of one output row
            // ========================================================
            S_ROW_DONE: begin
                if (current_row_y_reg == OUT_LAST) begin
                    row_y_next = 8'd0;
                    y_acc_next = 32'd0;
                end else begin
                    row_y_next = current_row_y_reg + 8'd1;

                    // Only real image rows advance the Y accumulator.
                    if (row_real_image)
                        y_acc_next = y_acc_plus_step;
                end

                state_next = S_IDLE;
            end

            default: begin
                state_next = S_IDLE;
            end

        endcase
    end

endmodule
