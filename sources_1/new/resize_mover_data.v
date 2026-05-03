`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/03/2026 05:23:35 PM
// Design Name: 
// Module Name: resize_mover_data
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
module resize_mover_data#(
    parameter                           ADDR_WIDTH = 24,
    parameter                           BURST_SELECT_WIDTH = 16,
    parameter                           DATA_WIDTH_BYTE = 1
)(
    // ============================================================
    // System
    // ============================================================
    input                               clk_i,
    input                               resetn_i,
    
    //
    input   signed [31:0]               scale_inf_mult_reg,
    input          [5:0]                scale_inf_mult_shift_reg,
    input   signed [7:0]                zp_i,

    // ============================================================
    // Frame buffer read interface
    // latency = 1 clock
    // ============================================================
    output  [ADDR_WIDTH-1:0]            fb_addr_o,
    input   [15:0]                      fb_pixel_data_i,

    // handshaking accel signal
    input                               ARVALID_i,
    output                              ARREADY_o,
    input   [ADDR_WIDTH-1:0]            ARADDR_i,
    input   [BURST_SELECT_WIDTH-1:0]    ARBURST_i,

    // --- AXIS Master Port (Read data out for Accel) ---
    output                              m_tvalid_o,
    input                               m_tready_i,
    output  [DATA_WIDTH_BYTE*8-1:0]     m_tdata_o,
    output  [DATA_WIDTH_BYTE-1:0]       m_tstrb_o,
    output  [DATA_WIDTH_BYTE-1:0]       m_tkeep_o,
    output                              m_tlast_o,
    output                              m_tid_o

    );


    wire                          R_tvalid_i;
    wire                          R_tready_o;
    wire  [DATA_WIDTH_BYTE*8-1:0] R_tdata_i;
    wire  [DATA_WIDTH_BYTE-1:0]   R_tstrb_i;
    wire  [DATA_WIDTH_BYTE-1:0]   R_tkeep_i;
    wire                          R_tlast_i;
    wire                          R_tid_i;

    wire                          G_tvalid_i;
    wire                          G_tready_o;
    wire  [DATA_WIDTH_BYTE*8-1:0] G_tdata_i;
    wire  [DATA_WIDTH_BYTE-1:0]   G_tstrb_i;
    wire  [DATA_WIDTH_BYTE-1:0]   G_tkeep_i;
    wire                          G_tlast_i;
    wire                          G_tid_i;

    wire                          B_tvalid_i;
    wire                          B_tready_o;
    wire  [DATA_WIDTH_BYTE*8-1:0] B_tdata_i;
    wire  [DATA_WIDTH_BYTE-1:0]   B_tstrb_i;
    wire  [DATA_WIDTH_BYTE-1:0]   B_tkeep_i;
    wire                          B_tlast_i;
    wire                          B_tid_i;


    wire    [2:0] select_data_channel_rgb_w;


    wire                          ff_wr_rgb_buf;
    wire                          ff_tlast_pixel;
    wire    [7:0]                 ff_r_pixel_data;
    wire    [7:0]                 ff_g_pixel_data;
    wire    [7:0]                 ff_b_pixel_data;

    wire    [ADDR_WIDTH-1:0]      rm_addr_base;
    wire                          rm_valid;
    wire                          rm_ready;


    control_data_resize_image #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .BURST_SELECT_WIDTH(BURST_SELECT_WIDTH)
    ) control_data_resize_image_uut (
        .clk_i(clk_i),
        .resetn_i(resetn_i),
        .ARVALID_i(ARVALID_i),
        .ARREADY_o(ARREADY_o),
        .ARADDR_i(ARADDR_i),
        .ARBURST_i(ARBURST_i),
        .select_data_channel_rgb_o(select_data_channel_rgb_w),
        .tvalid_data_channel_rgb_i(m_tvalid_o),
        .tready_data_channel_rgb_i(m_tready_i),
        .tlast_data_channel_rgb_i(m_tlast_o),
        .rm_addr_base_o(rm_addr_base),
        .rm_valid_o(rm_valid),
        .rm_ready_i(rm_ready)
    );


    resize_maxpooling #(
        .ADDR_WIDTH_BASE (ADDR_WIDTH)
    ) resize_maxpooling_uut (
        .clk_i                    (clk_i),
        .resetn_i                 (resetn_i),

        .scale_inf_mult_reg       (scale_inf_mult_reg),
        .scale_inf_mult_shift_reg (scale_inf_mult_shift_reg),
        .zp_i                     (zp_i),

        .cal_addr_base_i          (rm_addr_base),
        .cal_valid_i              (rm_valid),
        .cal_ready_o              (rm_ready),

        .fb_addr_o                (fb_addr_o),
        .fb_pixel_data_i          (fb_pixel_data_i),

        .ff_wr_rgb_buf_o          (ff_wr_rgb_buf),
        .ff_tlast_pixel_o         (ff_tlast_pixel),
        .ff_r_pixel_data_o        (ff_r_pixel_data),
        .ff_g_pixel_data_o        (ff_g_pixel_data),
        .ff_b_pixel_data_o        (ff_b_pixel_data)
    );





    axi4_stream #(
        .DATA_WIDTH_BYTE  (DATA_WIDTH_BYTE), 
        .SELECT_INTERFACE (0),  // 0 master
        .SIZE_FIFO        (9)
    ) fifo_R_channel (
        .aclk_i           (clk_i), 
        .aresetn_i        (resetn_i), 
        
        // Output Ports
        .m_tvalid_o       (R_tvalid_i), 
        .m_tready_i       (R_tready_o), 
        .m_tdata_o        (R_tdata_i), 
        .m_tstrb_o        (R_tstrb_i), 
        .m_tkeep_o        (R_tkeep_i), 
        .m_tlast_o        (R_tlast_i), 
        .m_tid_o          (R_tid_i),
        
   
        .user_m_wr_data_i (ff_wr_rgb_buf), 
        .user_m_data_i    (ff_r_pixel_data), 
        .user_m_tstrb_i   (0), 
        .user_m_tkeep_i   (0), 
        .user_m_tlast_i   (ff_tlast_pixel),
        .user_m_tid_i     (0), 
        
        // Unused Ports
        .user_m_busy_o    (), 
        .s_tready_o       (), 
        .user_s_ready_o   (), 
        .user_s_data_o    ()
    );

    axi4_stream #(
        .DATA_WIDTH_BYTE  (DATA_WIDTH_BYTE), 
        .SELECT_INTERFACE (0),  // 0 master
        .SIZE_FIFO        (9)
    ) fifo_G_channel (
        .aclk_i           (clk_i), 
        .aresetn_i        (resetn_i), 
        
        // Output Ports
        .m_tvalid_o       (G_tvalid_i), 
        .m_tready_i       (G_tready_o), 
        .m_tdata_o        (G_tdata_i), 
        .m_tstrb_o        (G_tstrb_i), 
        .m_tkeep_o        (G_tkeep_i), 
        .m_tlast_o        (G_tlast_i), 
        .m_tid_o          (G_tid_i),
        
  
        .user_m_wr_data_i (ff_wr_rgb_buf), 
        .user_m_data_i    (ff_g_pixel_data), 
        .user_m_tstrb_i   (0), 
        .user_m_tkeep_i   (0), 
        .user_m_tlast_i   (ff_tlast_pixel),
        .user_m_tid_i     (0), 
        
        // Unused Ports
        .user_m_busy_o    (), 
        .s_tready_o       (), 
        .user_s_ready_o   (), 
        .user_s_data_o    ()
    );

    axi4_stream #(
        .DATA_WIDTH_BYTE  (DATA_WIDTH_BYTE), 
        .SELECT_INTERFACE (0),  // 0 master
        .SIZE_FIFO        (9)
    ) fifo_B_channel (
        .aclk_i           (clk_i), 
        .aresetn_i        (resetn_i), 
        
        // Output Ports
        .m_tvalid_o       (B_tvalid_i), 
        .m_tready_i       (B_tready_o), 
        .m_tdata_o        (B_tdata_i), 
        .m_tstrb_o        (B_tstrb_i), 
        .m_tkeep_o        (B_tkeep_i), 
        .m_tlast_o        (B_tlast_i), 
        .m_tid_o          (B_tid_i),
        

        .user_m_wr_data_i (ff_wr_rgb_buf), 
        .user_m_data_i    (ff_b_pixel_data), 
        .user_m_tstrb_i   (0), 
        .user_m_tkeep_i   (0), 
        .user_m_tlast_i   (ff_tlast_pixel),
        .user_m_tid_i     (0), 
        
        // Unused Ports
        .user_m_busy_o    (), 
        .s_tready_o       (), 
        .user_s_ready_o   (), 
        .user_s_data_o    ()
    );


    // wire [2:0] select_data_channel_rgb_w; 

    encoder_3to1_axis_interface #(
        .DATA_WIDTH_BYTE           (DATA_WIDTH_BYTE)
    ) encoder_3to1_uut (
        .select_data_channel_rgb_i (select_data_channel_rgb_w), // Nối từ control_data_resize_image_uut
        
        // Master interface port 0 (R Channel)
        .mR_tvalid_i               (R_tvalid_i),
        .mR_tready_o               (R_tready_o),
        .mR_tdata_i                (R_tdata_i),
        .mR_tstrb_i                (R_tstrb_i),
        .mR_tkeep_i                (R_tkeep_i),
        .mR_tlast_i                (R_tlast_i),
        .mR_tid_i                  (R_tid_i),

        // Master interface port 1 (G Channel)
        .mG_tvalid_i               (G_tvalid_i),
        .mG_tready_o               (G_tready_o),
        .mG_tdata_i                (G_tdata_i),
        .mG_tstrb_i                (G_tstrb_i),
        .mG_tkeep_i                (G_tkeep_i),
        .mG_tlast_i                (G_tlast_i),
        .mG_tid_i                  (G_tid_i),

        // Master interface port 2 (B Channel)
        .mB_tvalid_i               (B_tvalid_i),
        .mB_tready_o               (B_tready_o),
        .mB_tdata_i                (B_tdata_i),
        .mB_tstrb_i                (B_tstrb_i),
        .mB_tkeep_i                (B_tkeep_i),
        .mB_tlast_i                (B_tlast_i),
        .mB_tid_i                  (B_tid_i),

        // Master select interface port (Output for Accel)
        .s_tvalid1_o               (m_tvalid_o),
        .s_tready1_i               (m_tready_i),
        .s_tdata1_o                (m_tdata_o),
        .s_tstrb1_o                (m_tstrb_o),
        .s_tkeep1_o                (m_tkeep_o),
        .s_tlast1_o                (m_tlast_o),
        .s_tid_o                   (m_tid_o)
    );



endmodule



module encoder_3to1_axis_interface #(
    parameter DATA_WIDTH_BYTE = 1
)(  
    input  [2:0]                   select_data_channel_rgb_i, // onehot          
    
    //master interface port 0 (R Channel)
    input                          mR_tvalid_i,
    output                         mR_tready_o,
    input  [DATA_WIDTH_BYTE*8-1:0] mR_tdata_i,
    input  [DATA_WIDTH_BYTE-1:0]   mR_tstrb_i,
    input  [DATA_WIDTH_BYTE-1:0]   mR_tkeep_i,
    input                          mR_tlast_i,
    input                          mR_tid_i,

    //master interface port 1 (G Channel)
    input                          mG_tvalid_i,
    output                         mG_tready_o,
    input  [DATA_WIDTH_BYTE*8-1:0] mG_tdata_i,
    input  [DATA_WIDTH_BYTE-1:0]   mG_tstrb_i,
    input  [DATA_WIDTH_BYTE-1:0]   mG_tkeep_i,
    input                          mG_tlast_i,
    input                          mG_tid_i,

    //master interface port 2 (B Channel)
    input                          mB_tvalid_i,
    output                         mB_tready_o,
    input  [DATA_WIDTH_BYTE*8-1:0] mB_tdata_i,
    input  [DATA_WIDTH_BYTE-1:0]   mB_tstrb_i,
    input  [DATA_WIDTH_BYTE-1:0]   mB_tkeep_i,
    input                          mB_tlast_i,
    input                          mB_tid_i,

    //master select interface port (Output to downstream)
    output                         s_tvalid1_o,
    input                          s_tready1_i,
    output [DATA_WIDTH_BYTE*8-1:0] s_tdata1_o,
    output [DATA_WIDTH_BYTE-1:0]   s_tstrb1_o,
    output [DATA_WIDTH_BYTE-1:0]   s_tkeep1_o,
    output                         s_tlast1_o,
    output                         s_tid_o 
);

    // ============================================================
    // Logic MUX AXI-Stream
    // Quy ước select_data_channel_rgb_i (One-Hot):
    // Bit [2] : Chọn kênh R (Cao nhất)
    // Bit [1] : Chọn kênh G
    // Bit [0] : Chọn kênh B (Thấp nhất)
    // ============================================================

    // 1. Dồn kênh (Multiplexing) cho Data, Strb, Keep, và ID
    assign s_tdata1_o  = select_data_channel_rgb_i[2] ? mR_tdata_i :
                         select_data_channel_rgb_i[1] ? mG_tdata_i :
                         select_data_channel_rgb_i[0] ? mB_tdata_i : {(DATA_WIDTH_BYTE*8){1'b0}};

    assign s_tstrb1_o  = select_data_channel_rgb_i[2] ? mR_tstrb_i :
                         select_data_channel_rgb_i[1] ? mG_tstrb_i :
                         select_data_channel_rgb_i[0] ? mB_tstrb_i : {DATA_WIDTH_BYTE{1'b0}};

    assign s_tkeep1_o  = select_data_channel_rgb_i[2] ? mR_tkeep_i :
                         select_data_channel_rgb_i[1] ? mG_tkeep_i :
                         select_data_channel_rgb_i[0] ? mB_tkeep_i : {DATA_WIDTH_BYTE{1'b0}};

    assign s_tid_o     = select_data_channel_rgb_i[2] ? mR_tid_i :
                         select_data_channel_rgb_i[1] ? mG_tid_i :
                         select_data_channel_rgb_i[0] ? mB_tid_i : 1'b0;

    // 2. Dồn kênh cho tín hiệu Valid và Last 
    assign s_tvalid1_o = (select_data_channel_rgb_i[2] & mR_tvalid_i) |
                         (select_data_channel_rgb_i[1] & mG_tvalid_i) |
                         (select_data_channel_rgb_i[0] & mB_tvalid_i);

    assign s_tlast1_o  = (select_data_channel_rgb_i[2] & mR_tlast_i) |
                         (select_data_channel_rgb_i[1] & mG_tlast_i) |
                         (select_data_channel_rgb_i[0] & mB_tlast_i);

    // 3. Phân kênh (Demultiplexing) cho tín hiệu Ready
    assign mR_tready_o = select_data_channel_rgb_i[2] & s_tready1_i;
    assign mG_tready_o = select_data_channel_rgb_i[1] & s_tready1_i;
    assign mB_tready_o = select_data_channel_rgb_i[0] & s_tready1_i;

endmodule