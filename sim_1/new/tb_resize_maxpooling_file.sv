`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/03/2026 12:13:33 AM
// Design Name: 
// Module Name: tb_resize_maxpooling_file
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


`timescale 1ns/1ps

module tb_resize_maxpooling_file;

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

    localparam integer IN_PIXELS  = IN_W * IN_H;
    localparam integer OUT_PIXELS = OUT_SIZE * OUT_SIZE;

    // File input/output
    localparam FRAME_HEX   = "frame_640x480.hex";
    localparam CAPTURE_HEX = "rtl_capture_224.hex";

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
    // Frame buffer model
    // ============================================================
    //
    // frame_mem được load từ frame_640x480.hex.
    //
    // Frame buffer latency = 1 clock:
    //
    //   cycle N:
    //      DUT đưa fb_addr_o
    //
    //   cycle N+1:
    //      fb_pixel_data_i <= frame_mem[fb_addr_o]
    //
    // Mỗi dòng trong .hex là 1 pixel RGB565 16-bit.
    // Address là pixel address, không phải byte address.
    // ============================================================

    reg [15:0] frame_mem [0:IN_PIXELS-1];

    always @(posedge clk_i) begin
        if (fb_addr_o < IN_PIXELS)
            fb_pixel_data_i <= frame_mem[fb_addr_o];
        else
            fb_pixel_data_i <= 16'h0000;
    end

    // ============================================================
    // Capture output FIFO writes to rtl_capture_224.hex
    // ============================================================

    integer cap_fd;
    integer capture_count;
    integer row_pixel_count;
    integer tlast_error_count;

    always @(posedge clk_i) begin
        #1;

        if (ff_wr_rgb_buf_o) begin
            $fwrite(cap_fd, "%04h\n", ff_pixel_data_o);

            if (row_pixel_count == OUT_SIZE - 1) begin
                if (ff_tlast_pixel_o !== 1'b1) begin
                    $display("[%0t] ERROR: ff_tlast_pixel_o should be 1 at pixel %0d",
                             $time, capture_count);
                    tlast_error_count = tlast_error_count + 1;
                end
                row_pixel_count = 0;
            end else begin
                if (ff_tlast_pixel_o !== 1'b0) begin
                    $display("[%0t] ERROR: ff_tlast_pixel_o should be 0 at pixel %0d",
                             $time, capture_count);
                    tlast_error_count = tlast_error_count + 1;
                end
                row_pixel_count = row_pixel_count + 1;
            end

            capture_count = capture_count + 1;
        end
    end

    // ============================================================
    // DMA task: one handshake = one output row
    // ============================================================

    task automatic send_row_request;
        input integer row_idx;
        begin
            @(negedge clk_i);

            cal_addr_base_i = row_idx * OUT_SIZE;
            cal_valid_i     = 1'b1;

            while (cal_ready_o !== 1'b1) begin
                @(posedge clk_i);
                #1;
                @(negedge clk_i);
            end

            // Handshake at next posedge
            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            cal_valid_i = 1'b0;
        end
    endtask

    task automatic wait_row_done_by_tlast;
        input integer row_idx;
        integer timeout_count;
        integer start_count;
        begin
            timeout_count = 0;
            start_count   = capture_count;

            while (capture_count < start_count + OUT_SIZE) begin
                @(posedge clk_i);
                #1;
                timeout_count = timeout_count + 1;

                if (timeout_count > 50000) begin
                    $display("[%0t] ERROR: timeout waiting row %0d. captured=%0d expected_at_least=%0d",
                             $time, row_idx, capture_count, start_count + OUT_SIZE);
                    $finish;
                end
            end

            repeat (3) begin
                @(posedge clk_i);
                #1;
            end

            if (cal_ready_o !== 1'b1) begin
                $display("[%0t] ERROR: cal_ready_o should be high after row %0d",
                         $time, row_idx);
                tlast_error_count = tlast_error_count + 1;
            end
        end
    endtask

    task automatic run_one_row;
        input integer row_idx;
        begin
            send_row_request(row_idx);
            wait_row_done_by_tlast(row_idx);
        end
    endtask

    // ============================================================
    // Main test
    // ============================================================

    integer r;

    initial begin
        $dumpfile("tb_resize_maxpooling_file.vcd");
        $dumpvars(0, tb_resize_maxpooling_file);

        $display("=================================================");
        $display("TB resize_maxpooling_file started");
        $display("Input  hex: %s", FRAME_HEX);
        $display("Output hex: %s", CAPTURE_HEX);
        $display("=================================================");

        // Load frame buffer
        $readmemh(FRAME_HEX, frame_mem);

        cap_fd = $fopen(CAPTURE_HEX, "w");
        if (cap_fd == 0) begin
            $display("ERROR: cannot open %s", CAPTURE_HEX);
            $finish;
        end

        capture_count     = 0;
        row_pixel_count   = 0;
        tlast_error_count = 0;

        resetn_i        = 1'b0;
        cal_valid_i     = 1'b0;
        cal_addr_base_i = {ADDR_WIDTH_BASE{1'b0}};
        fb_pixel_data_i = 16'h0000;

        repeat (10) @(posedge clk_i);
        resetn_i = 1'b1;
        repeat (5) @(posedge clk_i);
        #1;

        if (cal_ready_o !== 1'b1) begin
            $display("[%0t] ERROR: cal_ready_o should be high after reset", $time);
            tlast_error_count = tlast_error_count + 1;
        end

        // Run full 224 rows.
        // cal_addr_base_i:
        //   row 0 -> 0
        //   row 1 -> 224
        //   row 2 -> 448
        //   ...
        for (r = 0; r < OUT_SIZE; r = r + 1) begin
            $display("[%0t] Start row %0d, base addr %0d", $time, r, r * OUT_SIZE);
            run_one_row(r);
        end

        repeat (20) @(posedge clk_i);
        #1;

        $fclose(cap_fd);

        $display("=================================================");
        $display("Captured pixels = %0d", capture_count);
        $display("Expected pixels = %0d", OUT_PIXELS);
        $display("TLAST errors    = %0d", tlast_error_count);
        $display("=================================================");

        if (capture_count != OUT_PIXELS) begin
            $display("TEST FAILED: output pixel count mismatch");
        end else if (tlast_error_count != 0) begin
            $display("TEST FAILED: TLAST/ready errors");
        end else begin
            $display("TEST DONE: use Python compare to check image data:");
            $display("  python3 img_hex_tool.py view --in-hex rtl_capture_224.hex --width 224 --height 224 --out-png rtl_capture_224.png");
            $display("  python3 img_hex_tool.py compare --expected expected_224.hex --actual rtl_capture_224.hex");
        end

        $finish;
    end

endmodule
