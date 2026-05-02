`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/02/2026 11:14:30 PM
// Design Name: 
// Module Name: tb_resize_maxpooling
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
module tb_resize_maxpooling;

    // ============================================================
    // Parameters matching DUT
    // ============================================================

    localparam ADDR_WIDTH_BASE = 24;

    localparam IN_W      = 640;
    localparam IN_H      = 480;

    localparam OUT_SIZE  = 224;
    localparam SCALED_H  = 168;
    localparam PAD_TOP   = 28;

    localparam FP        = 16;
    localparam X_STEP    = 32'd187245;
    localparam Y_STEP    = 32'd187245;

    localparam PRINT_MAPPING_DEBUG = 1;

    // ============================================================
    // Clock / reset
    // ============================================================

    reg clk_i;
    reg resetn_i;

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i;   // 100 MHz
    end

    // ============================================================
    // DUT signals
    // ============================================================

    reg  [ADDR_WIDTH_BASE-1:0] cal_addr_base_i;
    reg                        cal_valid_i;
    wire                       cal_ready_o;

    wire [ADDR_WIDTH_BASE-1:0] fb_addr_o;
    reg  [15:0]                fb_pixel_data_i;

    wire                       ff_wr_rgb_buf_o;
    wire                       ff_tlast_pixel_o;
    wire [15:0]                ff_pixel_data_o;

    // ============================================================
    // DUT instance
    // ============================================================

    resize_maxpooling #(
        .ADDR_WIDTH_BASE (ADDR_WIDTH_BASE),
        .IN_W            (IN_W),
        .IN_H            (IN_H),
        .OUT_SIZE        (OUT_SIZE),
        .SCALED_H        (SCALED_H),
        .PAD_TOP         (PAD_TOP),
        .FP              (FP),
        .X_STEP          (X_STEP),
        .Y_STEP          (Y_STEP)
    ) dut (
        .clk_i             (clk_i),
        .resetn_i          (resetn_i),

        .cal_addr_base_i   (cal_addr_base_i),
        .cal_valid_i       (cal_valid_i),
        .cal_ready_o       (cal_ready_o),

        .fb_addr_o         (fb_addr_o),
        .fb_pixel_data_i   (fb_pixel_data_i),

        .ff_wr_rgb_buf_o   (ff_wr_rgb_buf_o),
        .ff_tlast_pixel_o  (ff_tlast_pixel_o),
        .ff_pixel_data_o   (ff_pixel_data_o)
    );

    // ============================================================
    // Test counters
    // ============================================================

    integer error_count;
    integer total_checked;

    // ============================================================
    // Optional waveform dump
    // ============================================================

    initial begin
        $dumpfile("tb_resize_maxpooling.vcd");
        $dumpvars(0, tb_resize_maxpooling);
    end

    // ============================================================
    // Frame buffer model: synchronous 1-cycle latency
    // ============================================================
    //
    // cycle N:
    //     DUT đưa fb_addr_o
    //
    // cycle N+1:
    //     fb_pixel_data_i <= frame_pixel(fb_addr_o ở cycle N)
    //
    // Đây đúng với frame buffer của bạn:
    // đưa địa chỉ, 1 chu kỳ sau mới có data.
    // ============================================================

    always @(posedge clk_i) begin
        fb_pixel_data_i <= frame_pixel(fb_addr_o);
    end

    // ============================================================
    // Fake input image pattern
    // ============================================================
    //
    // Ảnh input giả lập 640x480 RGB565.
    //
    // addr = y * 640 + x
    //
    // Pattern cố tình làm R/G/B khác nhau để dễ bắt lỗi nếu DUT
    // không max pooling riêng từng kênh.
    // ============================================================

    function automatic [15:0] frame_pixel;
        input [ADDR_WIDTH_BASE-1:0] addr;

        integer x;
        integer y;

        reg [4:0] r;
        reg [5:0] g;
        reg [4:0] b;

        begin
            x = addr % IN_W;
            y = addr / IN_W;

            r = (x * 3  + y * 5 ) & 5'h1F;
            g = (x * 7  + y * 2 ) & 6'h3F;
            b = (x * 11 + y * 13) & 5'h1F;

            frame_pixel = {r, g, b};
        end
    endfunction

    // ============================================================
    // Expected output model
    // ============================================================
    //
    // Software model của thuật toán resize + max pooling:
    //
    // Nếu row thuộc padding:
    //     output = 16'h0000
    //
    // Nếu không padding:
    //     map output pixel về input window
    //     lấy max riêng R/G/B
    //     ghép lại RGB565
    // ============================================================

    function automatic [15:0] expected_pixel;
        input integer out_y;
        input integer out_x;

        integer img_y;

        integer src_x0;
        integer src_x1;
        integer src_y0;
        integer src_y1;

        integer xx;
        integer yy;
        integer addr;

        reg [15:0] pix;

        reg [4:0] max_r;
        reg [5:0] max_g;
        reg [4:0] max_b;

        begin
            if ((out_y < PAD_TOP) || (out_y >= (PAD_TOP + SCALED_H))) begin
                expected_pixel = 16'h0000;
            end else begin
                img_y = out_y - PAD_TOP;

                src_x0 = (out_x * X_STEP) >> FP;

                if (out_x == OUT_SIZE - 1)
                    src_x1 = IN_W - 1;
                else
                    src_x1 = (((out_x + 1) * X_STEP) >> FP) - 1;

                src_y0 = (img_y * Y_STEP) >> FP;

                if (img_y == SCALED_H - 1)
                    src_y1 = IN_H - 1;
                else
                    src_y1 = (((img_y + 1) * Y_STEP) >> FP) - 1;

                max_r = 5'd0;
                max_g = 6'd0;
                max_b = 5'd0;

                for (yy = src_y0; yy <= src_y1; yy = yy + 1) begin
                    for (xx = src_x0; xx <= src_x1; xx = xx + 1) begin
                        addr = yy * IN_W + xx;
                        pix  = frame_pixel(addr[ADDR_WIDTH_BASE-1:0]);

                        if (pix[15:11] > max_r)
                            max_r = pix[15:11];

                        if (pix[10:5] > max_g)
                            max_g = pix[10:5];

                        if (pix[4:0] > max_b)
                            max_b = pix[4:0];
                    end
                end

                expected_pixel = {max_r, max_g, max_b};
            end
        end
    endfunction

    // ============================================================
    // Print mapping from output pixel to input window
    // ============================================================
    //
    // Thứ tự input:
    //     print_mapping(out_y, out_x)
    //
    // Ví dụ:
    //     print_mapping(0, 0);
    //     print_mapping(28, 0);
    //     print_mapping(50, 10);
    // ============================================================

    task automatic print_mapping;
        input integer out_y;
        input integer out_x;

        integer img_y;

        integer src_x0;
        integer src_x1;
        integer src_y0;
        integer src_y1;

        integer xx;
        integer yy;
        integer addr;

        reg [15:0] pix;

        reg [4:0] max_r;
        reg [5:0] max_g;
        reg [4:0] max_b;

        begin
            $display("");
            $display("=================================================");
            $display("MAPPING CHECK");
            $display("Output pixel: out_x = %0d, out_y = %0d", out_x, out_y);

            if ((out_y < PAD_TOP) || (out_y >= (PAD_TOP + SCALED_H))) begin
                $display("This output pixel is in padding area.");
                $display("No input pixel from 640x480 is used.");
                $display("Output pixel = 16'h0000");
            end else begin
                img_y = out_y - PAD_TOP;

                src_x0 = (out_x * X_STEP) >> FP;

                if (out_x == OUT_SIZE - 1)
                    src_x1 = IN_W - 1;
                else
                    src_x1 = (((out_x + 1) * X_STEP) >> FP) - 1;

                src_y0 = (img_y * Y_STEP) >> FP;

                if (img_y == SCALED_H - 1)
                    src_y1 = IN_H - 1;
                else
                    src_y1 = (((img_y + 1) * Y_STEP) >> FP) - 1;

                $display("This output pixel is inside real image area.");
                $display("img_y = out_y - PAD_TOP = %0d - %0d = %0d",
                         out_y, PAD_TOP, img_y);

                $display("Input window:");
                $display("  src_x0 = %0d", src_x0);
                $display("  src_x1 = %0d", src_x1);
                $display("  src_y0 = %0d", src_y0);
                $display("  src_y1 = %0d", src_y1);

                $display("Window size:");
                $display("  width  = %0d", src_x1 - src_x0 + 1);
                $display("  height = %0d", src_y1 - src_y0 + 1);
                $display("  count  = %0d", (src_x1 - src_x0 + 1) * (src_y1 - src_y0 + 1));

                max_r = 5'd0;
                max_g = 6'd0;
                max_b = 5'd0;

                $display("");
                $display("Input pixels used:");

                for (yy = src_y0; yy <= src_y1; yy = yy + 1) begin
                    for (xx = src_x0; xx <= src_x1; xx = xx + 1) begin
                        addr = yy * IN_W + xx;
                        pix  = frame_pixel(addr[ADDR_WIDTH_BASE-1:0]);

                        if (pix[15:11] > max_r)
                            max_r = pix[15:11];

                        if (pix[10:5] > max_g)
                            max_g = pix[10:5];

                        if (pix[4:0] > max_b)
                            max_b = pix[4:0];

                        $display("  input_x=%0d input_y=%0d addr=%0d pixel=%h  R=%0d G=%0d B=%0d",
                                 xx,
                                 yy,
                                 addr,
                                 pix,
                                 pix[15:11],
                                 pix[10:5],
                                 pix[4:0]);
                    end
                end

                $display("");
                $display("Max pooling result:");
                $display("  max_r = %0d", max_r);
                $display("  max_g = %0d", max_g);
                $display("  max_b = %0d", max_b);
                $display("  output RGB565 = %h", {max_r, max_g, max_b});
            end

            $display("=================================================");
            $display("");
        end
    endtask

    // ============================================================
    // Reset task
    // ============================================================

    task automatic do_reset;
        begin
            resetn_i        = 1'b0;
            cal_valid_i     = 1'b0;
            cal_addr_base_i = {ADDR_WIDTH_BASE{1'b0}};
            fb_pixel_data_i = 16'd0;

            repeat (10) @(posedge clk_i);

            resetn_i = 1'b1;

            repeat (5) @(posedge clk_i);
            #1;

            if (cal_ready_o !== 1'b1) begin
                $display("[%0t] ERROR: cal_ready_o should be high after reset", $time);
                error_count = error_count + 1;
            end
        end
    endtask

    // ============================================================
    // Send one row request
    // ============================================================
    //
    // DMA protocol:
    //
    //     cal_valid_i     = 1
    //     cal_addr_base_i = row_idx * 224
    //
    // Khi DUT đang IDLE:
    //
    //     cal_ready_o = 1
    //
    // Handshake tại cạnh clock:
    //
    //     cal_valid_i && cal_ready_o
    //
    // Một handshake = DUT tự xuất 224 pixel của hàng đó.
    // ============================================================

    task automatic send_row_request;
        input integer row_idx;

        begin
            @(negedge clk_i);

            cal_addr_base_i = row_idx * OUT_SIZE;
            cal_valid_i     = 1'b1;

            // Chờ DUT ready
            while (cal_ready_o !== 1'b1) begin
                @(posedge clk_i);
                #1;
                @(negedge clk_i);
            end

            // Handshake xảy ra ở cạnh clock kế tiếp
            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            cal_valid_i = 1'b0;
        end
    endtask

    // ============================================================
    // Capture and check one output row
    // ============================================================

    task automatic capture_and_check_row;
        input integer row_idx;

        integer pixel_count;
        integer timeout_count;

        reg [15:0] exp_pix;

        begin
            pixel_count   = 0;
            timeout_count = 0;

            while (pixel_count < OUT_SIZE) begin
                @(posedge clk_i);
                #1;

                timeout_count = timeout_count + 1;

                if (timeout_count > 30000) begin
                    $display("[%0t] ERROR: timeout while waiting row %0d pixel %0d",
                             $time,
                             row_idx,
                             pixel_count);
                    error_count = error_count + 1;
                    return;
                end

                if (ff_wr_rgb_buf_o) begin
                    exp_pix = expected_pixel(row_idx, pixel_count);

                    if (ff_pixel_data_o !== exp_pix) begin
                        $display("[%0t] ERROR row=%0d col=%0d got=%h expected=%h",
                                 $time,
                                 row_idx,
                                 pixel_count,
                                 ff_pixel_data_o,
                                 exp_pix);
                        error_count = error_count + 1;
                    end

                    // tlast chỉ lên ở pixel cuối hàng
                    if (pixel_count == OUT_SIZE - 1) begin
                        if (ff_tlast_pixel_o !== 1'b1) begin
                            $display("[%0t] ERROR row=%0d col=%0d: ff_tlast_pixel_o should be 1",
                                     $time,
                                     row_idx,
                                     pixel_count);
                            error_count = error_count + 1;
                        end
                    end else begin
                        if (ff_tlast_pixel_o !== 1'b0) begin
                            $display("[%0t] ERROR row=%0d col=%0d: ff_tlast_pixel_o should be 0",
                                     $time,
                                     row_idx,
                                     pixel_count);
                            error_count = error_count + 1;
                        end
                    end

                    pixel_count   = pixel_count + 1;
                    total_checked = total_checked + 1;
                end
            end
        end
    endtask

    // ============================================================
    // Run one row
    // ============================================================

    task automatic run_one_row;
        input integer row_idx;

        begin
            send_row_request(row_idx);
            capture_and_check_row(row_idx);

            // Sau khi xong hàng, DUT sẽ cần 1-2 cycle để quay lại IDLE
            repeat (3) begin
                @(posedge clk_i);
                #1;
            end

            if (cal_ready_o !== 1'b1) begin
                $display("[%0t] ERROR: cal_ready_o should be high after finishing row %0d",
                         $time,
                         row_idx);
                error_count = error_count + 1;
            end
        end
    endtask

    // ============================================================
    // Run row range
    // ============================================================

    task automatic run_rows;
        input integer start_row;
        input integer end_row;

        integer r;

        begin
            for (r = start_row; r <= end_row; r = r + 1) begin
                run_one_row(r);
            end
        end
    endtask

    // ============================================================
    // Main test
    // ============================================================

    initial begin
        error_count   = 0;
        total_checked = 0;

        resetn_i        = 1'b0;
        cal_valid_i     = 1'b0;
        cal_addr_base_i = {ADDR_WIDTH_BASE{1'b0}};
        fb_pixel_data_i = 16'd0;

        $display("=================================================");
        $display("TB resize_maxpooling started");
        $display("Frame buffer model: synchronous 1-cycle latency");
        $display("=================================================");

        // ------------------------------------------------------------
        // Case 0: reset / ready
        // ------------------------------------------------------------
        $display("[CASE 0] Reset and cal_ready_o check");
        do_reset();

        // ------------------------------------------------------------
        // Debug mapping print
        // ------------------------------------------------------------
        if (PRINT_MAPPING_DEBUG) begin
            $display("[DEBUG] Print mapping examples");

            // Pixel này nằm trong padding top
            print_mapping(0, 0);

            // Dòng cuối padding top
            print_mapping(27, 0);

            // Pixel ảnh thật đầu tiên
            print_mapping(28, 0);

            // Pixel kế tiếp trong hàng ảnh thật đầu tiên
            print_mapping(28, 1);

            // Một pixel ở giữa ảnh
            print_mapping(50, 10);

            // Pixel cuối vùng ảnh thật
            print_mapping(195, 223);

            // Pixel padding bottom đầu tiên
            print_mapping(196, 0);
        end

        // ------------------------------------------------------------
        // Case 1: row 0, top padding
        // Expected: 224 black pixels, tlast on last pixel
        // ------------------------------------------------------------
        $display("[CASE 1] Row 0, top padding");
        run_one_row(0);

        // ------------------------------------------------------------
        // Reset lại để bắt đầu frame sạch.
        // ------------------------------------------------------------
        do_reset();

        // ------------------------------------------------------------
        // Case 2: rows 0..28
        // Rows 0..27 are padding.
        // Row 28 is first real image row.
        // ------------------------------------------------------------
        $display("[CASE 2] Rows 0..28, padding to first real row");
        run_rows(0, 28);

        // ------------------------------------------------------------
        // Reset lại để case sau bắt đầu frame sạch.
        // ------------------------------------------------------------
        do_reset();

        // ------------------------------------------------------------
        // Case 3: rows 0..196
        //
        // Cover:
        //   row 195 = last real image row
        //   row 196 = first bottom padding row
        //
        // Cần chạy tuần tự từ 0 vì DUT dùng counter hàng nội bộ.
        // ------------------------------------------------------------
        $display("[CASE 3] Rows 0..196, includes last real and first bottom padding");
        run_rows(0, 196);

        // ------------------------------------------------------------
        // Reset lại để full frame sạch.
        // ------------------------------------------------------------
        do_reset();

        // ------------------------------------------------------------
        // Case 4: full frame
        //
        // Cover:
        //   0..27    top padding
        //   28..195  real image
        //   196..223 bottom padding
        // ------------------------------------------------------------
        $display("[CASE 4] Full frame 224 rows");
        run_rows(0, OUT_SIZE - 1);

        repeat (20) @(posedge clk_i);

        $display("=================================================");
        $display("Total checked pixels = %0d", total_checked);
        $display("Total errors         = %0d", error_count);
        $display("=================================================");

        if (error_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
        end

        $finish;
    end

endmodule
