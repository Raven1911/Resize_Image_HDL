`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/02/2026 10:47:26 PM
// Design Name: 
// Module Name: resize_maxpooling
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
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
    // Input 640x480 = 4:3
    // Resize giữ aspect ratio vào 224x224:
    //
    // scaled_w = 224
    // scaled_h = 224 * 480 / 640 = 168
    //
    // padding top    = 28
    // padding bottom = 28
    // ============================================================
    parameter SCALED_H  = 168,
    parameter PAD_TOP   = 28,

    // ============================================================
    // Fixed-point Q16.16
    //
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
    // DMA handshaking
    //
    // DMA đưa cal_valid_i = 1 cùng với cal_addr_base_i.
    // Một lần handshake nghĩa là resize xử lý 1 hàng 224 pixel.
    //
    // cal_addr_base_i:
    //   row 0 -> 0
    //   row 1 -> 224
    //   row 2 -> 448
    //   ...
    //
    // Module này hiện chưa dùng cal_addr_base_i để tạo địa chỉ output,
    // vì output đi ra FIFO. Nhưng nó dùng cal_addr_base_i == 0 để nhận
    // biết bắt đầu frame mới.
    // ============================================================
    input   [ADDR_WIDTH_BASE-1:0]       cal_addr_base_i,
    input                               cal_valid_i,
    output                              cal_ready_o,

    // ============================================================
    // Frame buffer read interface
    //
    // Giả định frame buffer latency = 1 clock:
    //   cycle N   : module đưa fb_addr_o
    //   cycle N+1 : fb_pixel_data_i hợp lệ
    // ============================================================
    output  [ADDR_WIDTH_BASE-1:0]       fb_addr_o,
    input   [15:0]                      fb_pixel_data_i,

    // ============================================================
    // FIFO output interface
    //
    // ff_wr_rgb_buf_o   : pulse 1 clock khi ff_pixel_data_o hợp lệ
    // ff_tlast_pixel_o  : lên 1 cùng pixel cuối hàng
    // ff_pixel_data_o   : RGB565 sau resize/maxpool
    //
    // Lưu ý: hiện chưa có FIFO full/ready, nên module giả định FIFO
    // luôn nhận được dữ liệu khi ff_wr_rgb_buf_o = 1.
    // ============================================================
    output                              ff_wr_rgb_buf_o,
    output                              ff_tlast_pixel_o,
    output  [15:0]                      ff_pixel_data_o
);

    // ============================================================
    // Local constants
    // ============================================================

    localparam [7:0] OUT_LAST       = OUT_SIZE - 1;          // 223
    localparam [7:0] PAD_TOP_8      = PAD_TOP;               // 28
    localparam [7:0] PAD_END_8      = PAD_TOP + SCALED_H;    // 196
    localparam [7:0] SCALED_H_LAST  = SCALED_H - 1;          // 167

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
    localparam S_EMIT_PIXEL  = 4'd5;
    localparam S_PAD_EMIT    = 4'd6;
    localparam S_ROW_DONE    = 4'd7;

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

    reg [15:0] ff_pixel_data_reg;
    reg [15:0] ff_pixel_data_next;

    assign fb_addr_o        = fb_addr_comb;
    assign ff_wr_rgb_buf_o  = ff_wr_rgb_buf_reg;
    assign ff_tlast_pixel_o = ff_tlast_pixel_reg;
    assign ff_pixel_data_o  = ff_pixel_data_reg;

    // ============================================================
    // DMA handshake
    // ============================================================

    assign cal_ready_o = (state_reg == S_IDLE);

    wire fire;
    assign fire = cal_valid_i && cal_ready_o;

    // ============================================================
    // Row / pixel counters
    // ============================================================
    //
    // row_y_reg:
    //   Hàng output hiện tại, từ 0 đến 223.
    //
    // current_row_y_reg:
    //   Hàng đang xử lý sau khi handshake.
    //
    // out_x_reg:
    //   Pixel x trong hàng hiện tại, từ 0 đến 223.
    // ============================================================

    reg [7:0] row_y_reg;
    reg [7:0] row_y_next;

    reg [7:0] current_row_y_reg;
    reg [7:0] current_row_y_next;

    reg [7:0] out_x_reg;
    reg [7:0] out_x_next;

    // Hàng hiện tại có nằm trong padding không?
    wire row_padding;

    assign row_padding =
        (current_row_y_reg < PAD_TOP_8) ||
        (current_row_y_reg >= PAD_END_8);

    // ============================================================
    // Y mapping
    // ============================================================
    //
    // Với output 224x224:
    //   row 0..27    là padding
    //   row 28..195  là ảnh thật
    //   row 196..223 là padding
    //
    // Nếu không padding:
    //   img_y = current_row_y - PAD_TOP
    //
    // Sau đó map về input:
    //   src_y0 = floor(img_y       * 480 / 168)
    //   src_y1 = floor((img_y + 1) * 480 / 168) - 1
    //
    // Vì trong một hàng output, y không đổi,
    // src_y0/src_y1 chỉ cần tính một lần cho cả hàng.
    // ============================================================

    reg [7:0] img_y_reg;
    reg [7:0] img_y_next;

    wire [39:0] mul_y0;
    wire [39:0] mul_y1;

    wire [8:0] calc_src_y0;
    wire [8:0] calc_src_y1_raw;

    assign mul_y0 = ({32'd0, img_y_reg} * Y_STEP);
    assign mul_y1 = ({32'd0, (img_y_reg + 8'd1)} * Y_STEP);

    assign calc_src_y0     = mul_y0 >> FP;
    assign calc_src_y1_raw = mul_y1 >> FP;

    reg [8:0] row_src_y0_reg;
    reg [8:0] row_src_y0_next;

    reg [8:0] row_src_y1_reg;
    reg [8:0] row_src_y1_next;

    // row_src_y0_base = row_src_y0 * 640
    // 640 = 512 + 128
    wire [18:0] calc_y0_base;

    assign calc_y0_base = (calc_src_y0 << 9) + (calc_src_y0 << 7);

    reg [18:0] row_src_y0_base_reg;
    reg [18:0] row_src_y0_base_next;

    // ============================================================
    // X mapping
    // ============================================================
    //
    // Với mỗi pixel out_x:
    //   src_x0 = floor(out_x       * 640 / 224)
    //   src_x1 = floor((out_x + 1) * 640 / 224) - 1
    //
    // src_x0/src_x1 thay đổi theo từng pixel output.
    // ============================================================

    wire [39:0] mul_x0;
    wire [39:0] mul_x1;

    wire [9:0] calc_src_x0;
    wire [9:0] calc_src_x1_raw;

    assign mul_x0 = ({32'd0, out_x_reg} * X_STEP);
    assign mul_x1 = ({32'd0, (out_x_reg + 8'd1)} * X_STEP);

    assign calc_src_x0     = mul_x0 >> FP;
    assign calc_src_x1_raw = mul_x1 >> FP;

    reg [9:0] src_x0_reg;
    reg [9:0] src_x0_next;

    reg [9:0] src_x1_reg;
    reg [9:0] src_x1_next;

    // ============================================================
    // Issue side
    // ============================================================
    //
    // Đây là phía phát địa chỉ đọc frame buffer.
    //
    // Trong S_STREAM:
    //   mỗi clock phát 1 địa chỉ fb_addr_o.
    //
    // Address input:
    //   input_addr = y * 640 + x
    //
    // Để nhẹ timing:
    //   issue_row_base_reg = y * 640
    //   issue_addr = issue_row_base_reg + issue_x_reg
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
    // ============================================================
    //
    // Frame buffer latency = 1 clock.
    //
    // Khi cycle N phát fb_addr_o,
    // cycle N+1 fb_pixel_data_i mới hợp lệ.
    //
    // rd_valid_reg và rd_last_reg là valid/last đã delay 1 clock
    // để khớp với fb_pixel_data_i.
    // ============================================================

    reg rd_valid_reg;
    reg rd_valid_next;

    reg rd_last_reg;
    reg rd_last_next;

    // ============================================================
    // RGB565 max pooling
    // ============================================================
    //
    // RGB565:
    //   R = pixel[15:11], 5 bit
    //   G = pixel[10:5],  6 bit
    //   B = pixel[4:0],   5 bit
    //
    // Max pooling phải lấy max riêng từng kênh.
    // Không được so sánh trực tiếp nguyên 16-bit RGB565.
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

    reg [15:0] pixel_result_reg;
    reg [15:0] pixel_result_next;

    // ============================================================
    // Sequential block
    // ============================================================
    //
    // Chỉ cập nhật register tại cạnh clock.
    // resetn_i active-low.
    // ============================================================

    always @(posedge clk_i) begin
        if (!resetn_i) begin
            state_reg <= S_IDLE;

            ff_wr_rgb_buf_reg   <= 1'b0;
            ff_tlast_pixel_reg  <= 1'b0;
            ff_pixel_data_reg   <= 16'd0;

            row_y_reg           <= 8'd0;
            current_row_y_reg   <= 8'd0;
            out_x_reg           <= 8'd0;

            img_y_reg           <= 8'd0;

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
        end else begin
            state_reg <= state_next;

            ff_wr_rgb_buf_reg   <= ff_wr_rgb_buf_next;
            ff_tlast_pixel_reg  <= ff_tlast_pixel_next;
            ff_pixel_data_reg   <= ff_pixel_data_next;

            row_y_reg           <= row_y_next;
            current_row_y_reg   <= current_row_y_next;
            out_x_reg           <= out_x_next;

            img_y_reg           <= img_y_next;

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
        end
    end

    // ============================================================
    // Combinational block
    // ============================================================
    //
    // Tính state_next và toàn bộ next-register.
    // ============================================================

    always @(*) begin
        // ------------------------------------------------------------
        // Default values
        // ------------------------------------------------------------
        state_next = state_reg;

        // fb_addr_o là combinational.
        // Khi không đọc, đưa về 0.
        fb_addr_comb = {ADDR_WIDTH_BASE{1'b0}};

        // FIFO output là pulse, default = 0
        ff_wr_rgb_buf_next   = 1'b0;
        ff_tlast_pixel_next  = 1'b0;
        ff_pixel_data_next   = ff_pixel_data_reg;

        row_y_next           = row_y_reg;
        current_row_y_next   = current_row_y_reg;
        out_x_next           = out_x_reg;

        img_y_next           = img_y_reg;

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

        case (state_reg)

            // ========================================================
            // S_IDLE
            // ========================================================
            //
            // Chờ DMA request.
            //
            // Một handshake:
            //   cal_valid_i = 1
            //   cal_ready_o = 1
            //
            // nghĩa là bắt đầu xử lý một hàng output 224 pixel.
            // ========================================================

            S_IDLE: begin
                issue_active_next = 1'b0;
                rd_valid_next     = 1'b0;
                rd_last_next      = 1'b0;

                if (fire) begin
                    // Bắt đầu mỗi hàng từ pixel x = 0
                    out_x_next = 8'd0;

                    // Nếu DMA đưa base address = 0,
                    // coi như bắt đầu frame mới.
                    if (cal_addr_base_i == {ADDR_WIDTH_BASE{1'b0}})
                        current_row_y_next = 8'd0;
                    else
                        current_row_y_next = row_y_reg;

                    state_next = S_ROW_SETUP;
                end
            end

            // ========================================================
            // S_ROW_SETUP
            // ========================================================
            //
            // Kiểm tra hàng hiện tại có phải padding không.
            //
            // Nếu padding:
            //   không đọc frame buffer, xuất 224 pixel đen.
            //
            // Nếu không padding:
            //   tính img_y = current_row_y - PAD_TOP.
            // ========================================================

            S_ROW_SETUP: begin
                if (row_padding) begin
                    state_next = S_PAD_EMIT;
                end else begin
                    img_y_next = current_row_y_reg - PAD_TOP_8;
                    state_next = S_ROW_Y_CALC;
                end
            end

            // ========================================================
            // S_ROW_Y_CALC
            // ========================================================
            //
            // Tính src_y0/src_y1 một lần cho cả hàng.
            //
            // row_src_y0_base = src_y0 * 640
            // để lát nữa phát địa chỉ nhanh hơn.
            // ========================================================

            S_ROW_Y_CALC: begin
                row_src_y0_next      = calc_src_y0;
                row_src_y0_base_next = calc_y0_base;

                if (img_y_reg == SCALED_H_LAST) begin
                    row_src_y1_next = IN_H_LAST;
                end else if (calc_src_y1_raw == 9'd0) begin
                    row_src_y1_next = 9'd0;
                end else begin
                    row_src_y1_next = calc_src_y1_raw - 9'd1;
                end

                state_next = S_PIXEL_SETUP;
            end

            // ========================================================
            // S_PIXEL_SETUP
            // ========================================================
            //
            // Tính src_x0/src_x1 cho pixel out_x hiện tại.
            //
            // Sau đó setup pipeline đọc window:
            //   issue_x        = src_x0
            //   issue_y        = src_y0
            //   issue_row_base = src_y0 * 640
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

                // Setup issue side
                issue_x_next        = calc_src_x0;
                issue_y_next        = row_src_y0_reg;
                issue_row_base_next = row_src_y0_base_reg;
                issue_active_next   = 1'b1;

                // Clear return side
                rd_valid_next = 1'b0;
                rd_last_next  = 1'b0;

                // Clear max accumulator for this output pixel
                max_r_next = 5'd0;
                max_g_next = 6'd0;
                max_b_next = 5'd0;

                state_next = S_STREAM;
            end

            // ========================================================
            // S_STREAM
            // ========================================================
            //
            // Pipeline đọc window.
            //
            // Frame buffer latency = 1 clock:
            //
            //   cycle N:
            //      fb_addr_o = address pixel input
            //
            //   cycle N+1:
            //      fb_pixel_data_i hợp lệ
            //      rd_valid_reg = 1
            //
            // Trong cùng một clock:
            //   - return side compare data cũ
            //   - issue side phát address mới
            // ========================================================

            S_STREAM: begin
                // ----------------------------------------------------
                // Return side
                // ----------------------------------------------------
                if (rd_valid_reg) begin
                    max_r_next = next_max_r;
                    max_g_next = next_max_g;
                    max_b_next = next_max_b;

                    if (rd_last_reg) begin
                        // Pixel hiện tại là pixel cuối trong window.
                        // Dùng next_max_* để không mất pixel cuối.
                        pixel_result_next = {next_max_r, next_max_g, next_max_b};
                        state_next        = S_EMIT_PIXEL;
                    end
                end

                // ----------------------------------------------------
                // Issue side
                // ----------------------------------------------------
                if (issue_active_reg) begin
                    // Xuất address combinational trong S_STREAM.
                    // Frame buffer sẽ trả data ở clock sau.
                    fb_addr_comb = {{(ADDR_WIDTH_BASE-19){1'b0}}, issue_addr};

                    // Delay valid/last đúng 1 clock để khớp data trả về.
                    rd_valid_next = 1'b1;
                    rd_last_next  = issue_last;

                    if (issue_last) begin
                        issue_active_next = 1'b0;
                    end else begin
                        if (issue_x_reg < src_x1_reg) begin
                            issue_x_next = issue_x_reg + 10'd1;
                        end else begin
                            // Hết một dòng trong window,
                            // quay về src_x0 và xuống dòng input tiếp theo.
                            issue_x_next        = src_x0_reg;
                            issue_y_next        = issue_y_reg + 9'd1;
                            issue_row_base_next = issue_row_base_reg + IN_W;
                        end
                    end
                end else begin
                    // Không phát thêm address.
                    // Nếu còn pixel cuối đang trả về thì rd_valid_reg cũ
                    // đã được xử lý ở return side phía trên.
                    rd_valid_next = 1'b0;
                    rd_last_next  = 1'b0;
                end
            end

            // ========================================================
            // S_EMIT_PIXEL
            // ========================================================
            //
            // Xuất pixel RGB565 đã maxpool ra FIFO.
            // ff_tlast_pixel_o lên cùng pixel cuối hàng.
            // ========================================================

            S_EMIT_PIXEL: begin
                ff_wr_rgb_buf_next   = 1'b1;
                ff_pixel_data_next   = pixel_result_reg;
                ff_tlast_pixel_next  = (out_x_reg == OUT_LAST);

                if (out_x_reg == OUT_LAST) begin
                    state_next = S_ROW_DONE;
                end else begin
                    out_x_next = out_x_reg + 8'd1;
                    state_next = S_PIXEL_SETUP;
                end
            end

            // ========================================================
            // S_PAD_EMIT
            // ========================================================
            //
            // Hàng padding.
            // Không đọc frame buffer.
            // Xuất 224 pixel đen RGB565.
            // ========================================================

            S_PAD_EMIT: begin
                ff_wr_rgb_buf_next   = 1'b1;
                ff_pixel_data_next   = 16'h0000;
                ff_tlast_pixel_next  = (out_x_reg == OUT_LAST);

                if (out_x_reg == OUT_LAST) begin
                    state_next = S_ROW_DONE;
                end else begin
                    out_x_next = out_x_reg + 8'd1;
                    state_next = S_PAD_EMIT;
                end
            end

            // ========================================================
            // S_ROW_DONE
            // ========================================================
            //
            // Xử lý xong 224 pixel của một hàng.
            // Quay về IDLE để nhận request hàng kế tiếp từ DMA.
            // ========================================================

            S_ROW_DONE: begin
                if (current_row_y_reg == OUT_LAST)
                    row_y_next = 8'd0;
                else
                    row_y_next = current_row_y_reg + 8'd1;

                state_next = S_IDLE;
            end

            default: begin
                state_next = S_IDLE;
            end

        endcase
    end

endmodule
