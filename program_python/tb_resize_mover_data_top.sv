`timescale 1ns/1ps

module tb_resize_mover_data_top;

    // ============================================================
    // Top-level parameters
    // ============================================================

    localparam ADDR_WIDTH        = 24;
    localparam BURST_SELECT_WIDTH = 16;
    localparam DATA_WIDTH_BYTE   = 1;

    // Image parameters
    localparam IN_W      = 640;
    localparam IN_H      = 480;
    localparam OUT_SIZE  = 224;
    localparam SCALED_H  = 168;
    localparam PAD_TOP   = 28;

    localparam FP        = 16;
    localparam X_STEP    = 32'd187245;
    localparam Y_STEP    = 32'd187245;

    localparam integer IN_PIXELS  = IN_W * IN_H;
    localparam integer OUT_PIXELS = OUT_SIZE * OUT_SIZE; // 50176

    // Channel plane base addresses expected by control_data_resize_image
    localparam integer R_BASE = 0;
    localparam integer G_BASE = OUT_PIXELS;
    localparam integer B_BASE = OUT_PIXELS * 2;

    // ============================================================
    // Quantization config used by DUT and golden model
    // ============================================================
    //
    // Default:
    //   q = pixel_u8 - 128
    //
    // Change these if you want to test another quantization config.
    // ============================================================

    localparam signed [31:0] SCALE_MULT  = 32'sd1;
    localparam        [5:0]  SCALE_SHIFT = 6'd0;
    localparam signed [7:0]  ZP          = -8'sd128;

    // ============================================================
    // File input/output
    // ============================================================

    localparam FRAME_HEX = "frame_640x480.hex";

    localparam CAPTURE_R_HEX = "top_axis_capture_r.hex";
    localparam CAPTURE_G_HEX = "top_axis_capture_g.hex";
    localparam CAPTURE_B_HEX = "top_axis_capture_b.hex";

    localparam EXPECT_R_HEX  = "top_expected_r.hex";
    localparam EXPECT_G_HEX  = "top_expected_g.hex";
    localparam EXPECT_B_HEX  = "top_expected_b.hex";

    // ============================================================
    // Optional testbench-only workarounds
    // ============================================================
    //
    // Your current resize_mover_data.v has two integration issues:
    //
    // 1. FIFO instances connect:
    //      .aclk_i(clk)
    //      .aresetn_i(rst_n)
    //    but the top ports are clk_i/resetn_i.
    //
    // 2. control_data_resize_image receives ff_tlast_pixel, but after
    //    selecting G/B there is no new ff_tlast_pixel pulse. For a
    //    read-channel controller, this should use selected AXIS tlast.
    //
    // If you have not fixed the RTL yet, keep these = 1 so the TB can
    // still verify the rest of the data path. For final verification of
    // the real RTL, fix the RTL and set these = 0.
    // ============================================================

    localparam APPLY_HIER_CLK_RST_FIX = 1;
    localparam APPLY_HIER_TLAST_FIX   = 1;

    // Check AXIS keep/strb.
    // Current resize_mover_data.v drives user_m_tkeep_i/user_m_tstrb_i = 0,
    // so keep this 0 unless you fix those to 1'b1.
    localparam CHECK_KEEP_STRB = 0;

    // You can reduce simulation time while debugging.
    localparam integer TEST_ROW_START = 0;
    localparam integer TEST_ROW_END   = OUT_SIZE - 1;

    // ============================================================
    // Clock / reset
    // ============================================================

    reg clk_i;
    reg resetn_i;

    initial begin
        clk_i = 1'b0;
        forever #5 clk_i = ~clk_i; // 100 MHz simulation clock
    end

    // ============================================================
    // DUT top-level signals
    // ============================================================

    wire [ADDR_WIDTH-1:0] fb_addr_o;
    reg  [15:0]           fb_pixel_data_i;

    reg                   ARVALID_i;
    wire                  ARREADY_o;
    reg  [ADDR_WIDTH-1:0] ARADDR_i;
    reg  [BURST_SELECT_WIDTH-1:0] ARBURST_i;

    wire                  m_tvalid_o;
    reg                   m_tready_i;
    wire [DATA_WIDTH_BYTE*8-1:0] m_tdata_o;
    wire [DATA_WIDTH_BYTE-1:0]   m_tstrb_o;
    wire [DATA_WIDTH_BYTE-1:0]   m_tkeep_o;
    wire                  m_tlast_o;
    wire                  m_tid_o;

    // ============================================================
    // DUT instance: full assembled IP
    // ============================================================

    resize_mover_data #(
        .ADDR_WIDTH         (ADDR_WIDTH),
        .BURST_SELECT_WIDTH (BURST_SELECT_WIDTH),
        .DATA_WIDTH_BYTE    (DATA_WIDTH_BYTE)
    ) dut (
        .clk_i                    (clk_i),
        .resetn_i                 (resetn_i),

        .scale_inf_mult_reg       (SCALE_MULT),
        .scale_inf_mult_shift_reg (SCALE_SHIFT),
        .zp_i                     (ZP),

        .fb_addr_o                (fb_addr_o),
        .fb_pixel_data_i          (fb_pixel_data_i),

        .ARVALID_i                (ARVALID_i),
        .ARREADY_o                (ARREADY_o),
        .ARADDR_i                 (ARADDR_i),
        .ARBURST_i                (ARBURST_i),

        .m_tvalid_o               (m_tvalid_o),
        .m_tready_i               (m_tready_i),
        .m_tdata_o                (m_tdata_o),
        .m_tstrb_o                (m_tstrb_o),
        .m_tkeep_o                (m_tkeep_o),
        .m_tlast_o                (m_tlast_o),
        .m_tid_o                  (m_tid_o)
    );

    // ============================================================
    // Testbench-only hierarchical workaround
    // ============================================================

    initial begin
        if (APPLY_HIER_CLK_RST_FIX) begin
            // Work around FIFO instances using implicit clk/rst_n instead of clk_i/resetn_i.
            force dut.clk   = clk_i;
            force dut.rst_n = resetn_i;
        end

        if (APPLY_HIER_TLAST_FIX) begin
            // Work around control waiting for resize ff_tlast_pixel instead of selected AXIS tlast.
            force dut.control_data_resize_image_uut.tlast_data_channel_rgb_i = m_tlast_o;
        end
    end

    // ============================================================
    // Frame buffer model
    // ============================================================
    //
    // Latency = 1 clock:
    //   cycle N   : DUT drives fb_addr_o
    //   cycle N+1 : fb_pixel_data_i <= frame_mem[fb_addr_o]
    // ============================================================

    reg [15:0] frame_mem [0:IN_PIXELS-1];

    always @(posedge clk_i) begin
        if (fb_addr_o < IN_PIXELS)
            fb_pixel_data_i <= frame_mem[fb_addr_o];
        else
            fb_pixel_data_i <= 16'h0000;
    end

    // ============================================================
    // Golden model helpers
    // ============================================================

    function automatic [7:0] expand_r5_to_r8;
        input [4:0] r5;
        begin
            expand_r5_to_r8 = {r5, r5[4:2]};
        end
    endfunction

    function automatic [7:0] expand_g6_to_g8;
        input [5:0] g6;
        begin
            expand_g6_to_g8 = {g6, g6[5:4]};
        end
    endfunction

    function automatic [7:0] expand_b5_to_b8;
        input [4:0] b5;
        begin
            expand_b5_to_b8 = {b5, b5[4:2]};
        end
    endfunction

    function automatic signed [7:0] golden_quant_u8;
        input [7:0] pixel_u8;

        reg signed [63:0] stage1;
        reg signed [63:0] stage2;
        reg signed [63:0] stage3;
        reg signed [63:0] stage4;
        reg signed [63:0] round_value;
        begin
            stage1 = $signed({1'b0, pixel_u8}) * SCALE_MULT;

            if (SCALE_SHIFT != 6'd0)
                round_value = 64'sd1 <<< (SCALE_SHIFT - 6'd1);
            else
                round_value = 64'sd0;

            stage2 = stage1 + round_value -
                     (((SCALE_SHIFT != 6'd0) && (stage1 < 0)) ? 64'sd1 : 64'sd0);

            if (SCALE_SHIFT != 6'd0)
                stage3 = stage2 >>> SCALE_SHIFT;
            else
                stage3 = stage2;

            stage4 = stage3 + ZP;

            if (stage4 > 64'sd127)
                golden_quant_u8 = 8'sd127;
            else if (stage4 < -64'sd128)
                golden_quant_u8 = -8'sd128;
            else
                golden_quant_u8 = stage4[7:0];
        end
    endfunction

    // Return:
    //   [23:16] = qR
    //   [15:8]  = qG
    //   [7:0]   = qB
    function automatic [23:0] expected_qrgb;
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
        reg [4:0] max_r5;
        reg [5:0] max_g6;
        reg [4:0] max_b5;
        reg [7:0] r8;
        reg [7:0] g8;
        reg [7:0] b8;
        reg signed [7:0] qr;
        reg signed [7:0] qg;
        reg signed [7:0] qb;

        begin
            if ((out_y < PAD_TOP) || (out_y >= (PAD_TOP + SCALED_H))) begin
                r8 = 8'd0;
                g8 = 8'd0;
                b8 = 8'd0;
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

                max_r5 = 5'd0;
                max_g6 = 6'd0;
                max_b5 = 5'd0;

                for (yy = src_y0; yy <= src_y1; yy = yy + 1) begin
                    for (xx = src_x0; xx <= src_x1; xx = xx + 1) begin
                        addr = yy * IN_W + xx;
                        pix  = frame_mem[addr];

                        if (pix[15:11] > max_r5)
                            max_r5 = pix[15:11];

                        if (pix[10:5] > max_g6)
                            max_g6 = pix[10:5];

                        if (pix[4:0] > max_b5)
                            max_b5 = pix[4:0];
                    end
                end

                r8 = expand_r5_to_r8(max_r5);
                g8 = expand_g6_to_g8(max_g6);
                b8 = expand_b5_to_b8(max_b5);
            end

            qr = golden_quant_u8(r8);
            qg = golden_quant_u8(g8);
            qb = golden_quant_u8(b8);

            expected_qrgb = {qr[7:0], qg[7:0], qb[7:0]};
        end
    endfunction

    function automatic [7:0] expected_channel_byte;
        input integer row;
        input integer col;
        input integer channel; // 0=R, 1=G, 2=B

        reg [23:0] qrgb;
        begin
            qrgb = expected_qrgb(row, col);

            case (channel)
                0: expected_channel_byte = qrgb[23:16];
                1: expected_channel_byte = qrgb[15:8];
                2: expected_channel_byte = qrgb[7:0];
                default: expected_channel_byte = 8'h00;
            endcase
        end
    endfunction

    // ============================================================
    // File descriptors and counters
    // ============================================================

    integer cap_r_fd;
    integer cap_g_fd;
    integer cap_b_fd;

    integer exp_r_fd;
    integer exp_g_fd;
    integer exp_b_fd;

    integer data_error_count;
    integer tlast_error_count;
    integer protocol_error_count;
    integer total_axis_beats;

    // ============================================================
    // AXI-like read address request
    // ============================================================

    task automatic send_ar_request;
        input [ADDR_WIDTH-1:0] addr;
        input [BURST_SELECT_WIDTH-1:0] burst_len;
        input [8*16-1:0] name;

        integer timeout_count;
        begin
            timeout_count = 0;

            @(negedge clk_i);
            ARADDR_i  = addr;
            ARBURST_i = burst_len;
            ARVALID_i = 1'b1;

            while (ARREADY_o !== 1'b1) begin
                @(posedge clk_i);
                #1;
                timeout_count = timeout_count + 1;

                if (timeout_count > 200000) begin
                    $display("[%0t] ERROR: timeout waiting ARREADY for %0s addr=%0d",
                             $time, name, addr);
                    $display("        This usually means control_data_resize_image is stuck.");
                    protocol_error_count = protocol_error_count + 1;
                    $finish;
                end

                @(negedge clk_i);
            end

            // Address handshake at next posedge
            @(posedge clk_i);
            #1;

            @(negedge clk_i);
            ARVALID_i = 1'b0;
            ARADDR_i  = {ADDR_WIDTH{1'b0}};
            ARBURST_i = {BURST_SELECT_WIDTH{1'b0}};
        end
    endtask

    // ============================================================
    // Capture one selected channel row from AXIS output
    // ============================================================

    task automatic capture_axis_row;
        input integer row_idx;
        input integer channel; // 0=R, 1=G, 2=B

        integer col;
        integer timeout_count;
        reg [7:0] got;
        reg [7:0] exp;
        reg [8*8-1:0] ch_name;
        begin
            col = 0;
            timeout_count = 0;

            case (channel)
                0: ch_name = "R";
                1: ch_name = "G";
                2: ch_name = "B";
                default: ch_name = "?";
            endcase

            while (col < OUT_SIZE) begin
                @(posedge clk_i);
                #1;
                timeout_count = timeout_count + 1;

                if (timeout_count > 300000) begin
                    $display("[%0t] ERROR: timeout waiting AXIS data row=%0d channel=%0s col=%0d",
                             $time, row_idx, ch_name, col);
                    protocol_error_count = protocol_error_count + 1;
                    $finish;
                end

                if (m_tvalid_o && m_tready_i) begin
                    got = m_tdata_o[7:0];
                    exp = expected_channel_byte(row_idx, col, channel);

                    case (channel)
                        0: begin
                            $fwrite(cap_r_fd, "%02h\n", got);
                            $fwrite(exp_r_fd, "%02h\n", exp);
                        end
                        1: begin
                            $fwrite(cap_g_fd, "%02h\n", got);
                            $fwrite(exp_g_fd, "%02h\n", exp);
                        end
                        2: begin
                            $fwrite(cap_b_fd, "%02h\n", got);
                            $fwrite(exp_b_fd, "%02h\n", exp);
                        end
                    endcase

                    if (got !== exp) begin
                        $display("[%0t] ERROR DATA channel=%0s row=%0d col=%0d got=%02h expected=%02h",
                                 $time, ch_name, row_idx, col, got, exp);
                        data_error_count = data_error_count + 1;
                    end

                    if (CHECK_KEEP_STRB) begin
                        if (m_tkeep_o !== {DATA_WIDTH_BYTE{1'b1}}) begin
                            $display("[%0t] ERROR: m_tkeep_o should be 1 on valid data", $time);
                            protocol_error_count = protocol_error_count + 1;
                        end
                        if (m_tstrb_o !== {DATA_WIDTH_BYTE{1'b1}}) begin
                            $display("[%0t] ERROR: m_tstrb_o should be 1 on valid data", $time);
                            protocol_error_count = protocol_error_count + 1;
                        end
                    end

                    if (col == OUT_SIZE - 1) begin
                        if (m_tlast_o !== 1'b1) begin
                            $display("[%0t] ERROR TLAST channel=%0s row=%0d col=%0d should be 1",
                                     $time, ch_name, row_idx, col);
                            tlast_error_count = tlast_error_count + 1;
                        end
                    end else begin
                        if (m_tlast_o !== 1'b0) begin
                            $display("[%0t] ERROR TLAST channel=%0s row=%0d col=%0d should be 0",
                                     $time, ch_name, row_idx, col);
                            tlast_error_count = tlast_error_count + 1;
                        end
                    end

                    col = col + 1;
                    total_axis_beats = total_axis_beats + 1;
                end
            end
        end
    endtask

    // ============================================================
    // Read one row for one channel through assembled IP
    // ============================================================

    task automatic read_channel_row;
        input integer row_idx;
        input integer channel; // 0=R, 1=G, 2=B

        integer addr;
        reg [8*16-1:0] name;
        begin
            case (channel)
                0: begin
                    addr = R_BASE + row_idx * OUT_SIZE;
                    name = "READ_R";
                end
                1: begin
                    addr = G_BASE + row_idx * OUT_SIZE;
                    name = "READ_G";
                end
                2: begin
                    addr = B_BASE + row_idx * OUT_SIZE;
                    name = "READ_B";
                end
                default: begin
                    addr = 0;
                    name = "READ_?";
                end
            endcase

            send_ar_request(addr[ADDR_WIDTH-1:0], OUT_SIZE[BURST_SELECT_WIDTH-1:0], name);
            capture_axis_row(row_idx, channel);

            // Give control a few clocks to return to IDLE.
            repeat (5) begin
                @(posedge clk_i);
                #1;
            end
        end
    endtask

    // ============================================================
    // Main test
    // ============================================================

    integer r;

    initial begin
        $dumpfile("tb_resize_mover_data_top.vcd");
        $dumpvars(0, tb_resize_mover_data_top);

        $display("=================================================");
        $display("TB resize_mover_data_top started");
        $display("Input image hex: %s", FRAME_HEX);
        $display("Rows tested: %0d..%0d", TEST_ROW_START, TEST_ROW_END);
        $display("Quant config: mult=%0d shift=%0d zp=%0d", SCALE_MULT, SCALE_SHIFT, ZP);
        $display("Hier clk/rst workaround  = %0d", APPLY_HIER_CLK_RST_FIX);
        $display("Hier tlast workaround    = %0d", APPLY_HIER_TLAST_FIX);
        $display("=================================================");

        $readmemh(FRAME_HEX, frame_mem);

        cap_r_fd = $fopen(CAPTURE_R_HEX, "w");
        cap_g_fd = $fopen(CAPTURE_G_HEX, "w");
        cap_b_fd = $fopen(CAPTURE_B_HEX, "w");

        exp_r_fd = $fopen(EXPECT_R_HEX, "w");
        exp_g_fd = $fopen(EXPECT_G_HEX, "w");
        exp_b_fd = $fopen(EXPECT_B_HEX, "w");

        if ((cap_r_fd == 0) || (cap_g_fd == 0) || (cap_b_fd == 0) ||
            (exp_r_fd == 0) || (exp_g_fd == 0) || (exp_b_fd == 0)) begin
            $display("ERROR: cannot open output capture/expected files");
            $finish;
        end

        data_error_count     = 0;
        tlast_error_count    = 0;
        protocol_error_count = 0;
        total_axis_beats     = 0;

        resetn_i        = 1'b0;
        fb_pixel_data_i = 16'h0000;
        ARVALID_i       = 1'b0;
        ARADDR_i        = {ADDR_WIDTH{1'b0}};
        ARBURST_i       = {BURST_SELECT_WIDTH{1'b0}};
        m_tready_i      = 1'b1;

        repeat (20) @(posedge clk_i);
        resetn_i = 1'b1;
        repeat (10) @(posedge clk_i);
        #1;

        // ========================================================
        // Per row:
        //   1. R request triggers resize for this row and reads R FIFO.
        //   2. G request reads G FIFO already filled by same resize.
        //   3. B request reads B FIFO already filled by same resize.
        //
        // This keeps G/B FIFOs from overflowing.
        // ========================================================

        for (r = TEST_ROW_START; r <= TEST_ROW_END; r = r + 1) begin
            $display("[%0t] Row %0d: read R", $time, r);
            read_channel_row(r, 0);

            $display("[%0t] Row %0d: read G", $time, r);
            read_channel_row(r, 1);

            $display("[%0t] Row %0d: read B", $time, r);
            read_channel_row(r, 2);
        end

        repeat (20) @(posedge clk_i);
        #1;

        $fclose(cap_r_fd);
        $fclose(cap_g_fd);
        $fclose(cap_b_fd);
        $fclose(exp_r_fd);
        $fclose(exp_g_fd);
        $fclose(exp_b_fd);

        $display("=================================================");
        $display("Total AXIS beats       = %0d", total_axis_beats);
        $display("Expected AXIS beats    = %0d", (TEST_ROW_END - TEST_ROW_START + 1) * OUT_SIZE * 3);
        $display("Data errors            = %0d", data_error_count);
        $display("TLAST errors           = %0d", tlast_error_count);
        $display("Protocol errors        = %0d", protocol_error_count);
        $display("=================================================");

        if (data_error_count == 0 &&
            tlast_error_count == 0 &&
            protocol_error_count == 0 &&
            total_axis_beats == ((TEST_ROW_END - TEST_ROW_START + 1) * OUT_SIZE * 3)) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
        end

        $display("");
        $display("Generated files:");
        $display("  %s / %s", CAPTURE_R_HEX, EXPECT_R_HEX);
        $display("  %s / %s", CAPTURE_G_HEX, EXPECT_G_HEX);
        $display("  %s / %s", CAPTURE_B_HEX, EXPECT_B_HEX);
        $display("You can diff them:");
        $display("  diff %s %s", EXPECT_R_HEX, CAPTURE_R_HEX);
        $display("  diff %s %s", EXPECT_G_HEX, CAPTURE_G_HEX);
        $display("  diff %s %s", EXPECT_B_HEX, CAPTURE_B_HEX);

        $finish;
    end

endmodule
