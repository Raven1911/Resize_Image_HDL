`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/03/2026 05:10:02 PM
// Design Name: 
// Module Name: tb_control_data_resize_image
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


module tb_control_data_resize_image();

    // 1. Khai báo Parameters (giống module chính)
    parameter ADDR_WIDTH = 24;
    parameter BURST_SELECT_WIDTH = 16;

    // 2. Khai báo các tín hiệu I/O
    // Inputs (dùng reg)
    reg clk_i;
    reg resetn_i;
    reg ARVALID_i;
    reg [ADDR_WIDTH-1:0] ARADDR_i;
    reg [BURST_SELECT_WIDTH-1:0] ARBURST_i;
    reg tlast_data_channel_rgb_i;
    reg rm_ready_i;

    // Outputs (dùng wire)
    wire ARREADY_o;
    wire [2:0] select_data_channel_rgb_o;
    wire [ADDR_WIDTH-1:0] rm_addr_base_o;
    wire rm_valid_o;

    // 3. Khởi tạo Module (UUT - Unit Under Test)
    control_data_resize_image #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .BURST_SELECT_WIDTH(BURST_SELECT_WIDTH)
    ) uut (
        .clk_i(clk_i),
        .resetn_i(resetn_i),
        .ARVALID_i(ARVALID_i),
        .ARREADY_o(ARREADY_o),
        .ARADDR_i(ARADDR_i),
        .ARBURST_i(ARBURST_i),
        .select_data_channel_rgb_o(select_data_channel_rgb_o),
        .tlast_data_channel_rgb_i(tlast_data_channel_rgb_i),
        .rm_addr_base_o(rm_addr_base_o),
        .rm_valid_o(rm_valid_o),
        .rm_ready_i(rm_ready_i)
    );

    // 4. Tạo xung Clock (Chu kỳ 10ns -> 100MHz)
    initial begin
        clk_i = 0;
        forever #5 clk_i = ~clk_i;
    end

    // 5. Quá trình tạo kích thích (Stimulus Process)
    initial begin
        // Khởi tạo giá trị ban đầu
        resetn_i = 0;
        ARVALID_i = 0;
        ARADDR_i = 0;
        ARBURST_i = 0;
        tlast_data_channel_rgb_i = 0;
        rm_ready_i = 0;

        // Bỏ reset sau 20ns
        #20;
        resetn_i = 1;
        #20;

        // ==============================================================
        // TEST CASE 1: RED CHANNEL (0 <= ARADDR < 50176)
        // ==============================================================
        $display("--- BAT DAU TEST 1: RED CHANNEL ---");
        @(posedge clk_i);
        ARVALID_i = 1;
        ARADDR_i = 24'd1000; // Nằm trong khoảng Red
        
        // Đợi module phản hồi ARREADY_o
        wait(ARREADY_o);
        @(posedge clk_i);
        ARVALID_i = 0; // Kéo Valid xuống sau khi handshake thành công

        // Module đang ở RED_SETUP0 -> Chờ rm_ready_i
        #20;
        @(posedge clk_i);
        rm_ready_i = 1;
        @(posedge clk_i);
        rm_ready_i = 0;

        // Module đang ở RED_SETUP1 -> Chờ tlast_data_channel_rgb_i để về IDLE
        #30;
        @(posedge clk_i);
        tlast_data_channel_rgb_i = 1;
        @(posedge clk_i);
        tlast_data_channel_rgb_i = 0;
        #40;

        // ==============================================================
        // TEST CASE 2: GREEN CHANNEL (50176 <= ARADDR < 100352)
        // ==============================================================
        $display("--- BAT DAU TEST 2: GREEN CHANNEL ---");
        @(posedge clk_i);
        ARVALID_i = 1;
        ARADDR_i = 24'd60000; // Nằm trong khoảng Green
        
        wait(ARREADY_o);
        @(posedge clk_i);
        ARVALID_i = 0;

        // Module đang ở GREEN_SETUP -> Chờ tlast_data_channel_rgb_i
        #30;
        @(posedge clk_i);
        tlast_data_channel_rgb_i = 1;
        @(posedge clk_i);
        tlast_data_channel_rgb_i = 0;
        #40;

        // ==============================================================
        // TEST CASE 3: BLUE CHANNEL (ARADDR >= 100352)
        // ==============================================================
        $display("--- BAT DAU TEST 3: BLUE CHANNEL ---");
        @(posedge clk_i);
        ARVALID_i = 1;
        ARADDR_i = 24'd120000; // Lớn hơn 100352 -> Blue
        
        wait(ARREADY_o);
        @(posedge clk_i);
        ARVALID_i = 0;

        // Module đang ở BLUE_SETUP -> Chờ tlast_data_channel_rgb_i
        #30;
        @(posedge clk_i);
        tlast_data_channel_rgb_i = 1;
        @(posedge clk_i);
        tlast_data_channel_rgb_i = 0;
        #50;

        $display("--- HOAN THANH MO PHONG ---");
        $finish; // Kết thúc mô phỏng
    end

    // 6. In ra log trên Terminal để dễ debug
    initial begin
        $monitor("Time: %0t | ARVALID: %b | ARADDR: %0d | ARREADY: %b | State: %0d | RGB_Sel: %b | rm_valid: %b | rm_ready: %b | tlast: %b", 
                  $time, ARVALID_i, ARADDR_i, ARREADY_o, uut.state_reg, select_data_channel_rgb_o, rm_valid_o, rm_ready_i, tlast_data_channel_rgb_i);
    end

endmodule
