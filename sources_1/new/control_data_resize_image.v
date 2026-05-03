`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/03/2026 04:24:39 PM
// Design Name: 
// Module Name: control_data_resize_image
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
module control_data_resize_image#(
    parameter                           ADDR_WIDTH = 24,
    parameter                           BURST_SELECT_WIDTH = 16
)(
    //system signal
    input                               clk_i,
    input                               resetn_i,
    
    // handshaking accel signal
    input                               ARVALID_i,
    output                              ARREADY_o,
    input   [ADDR_WIDTH-1:0]            ARADDR_i,
    input   [BURST_SELECT_WIDTH-1:0]    ARBURST_i,

    //mux channel signal
    output  [2:0]                       select_data_channel_rgb_o, // {r,g,b}
    input                               tvalid_data_channel_rgb_i,
    input                               tready_data_channel_rgb_i,
    input                               tlast_data_channel_rgb_i,

    //handshaking resize signal 
    output  [ADDR_WIDTH-1:0]            rm_addr_base_o,
    output                              rm_valid_o,
    input                               rm_ready_i
    );


    localparam [3:0]    IDLE        = 'd0,
                        RED_SETUP0  = 'd1,
                        RED_SETUP1  = 'd2,
                        GREEN_SETUP = 'd3,
                        BLUE_SETUP  = 'd4;


    reg [3:0]               state_next, state_reg;

    //
    reg                     arready_next, arready_reg;
    reg [2:0]               select_data_channel_rgb_next, select_data_channel_rgb_reg;
    //
    reg [ADDR_WIDTH-1:0]    rm_addr_base_next, rm_addr_base_reg;
    reg                     rm_valid_next, rm_valid_reg;

    always @(posedge clk_i) begin
        if (~resetn_i) begin
            state_reg <= IDLE;
            arready_reg <= 0;
            select_data_channel_rgb_reg <= 0; 
            rm_addr_base_reg <= 0;
            rm_valid_reg <= 0;
        end
        else begin
            state_reg <= state_next;
            arready_reg <= arready_next;
            select_data_channel_rgb_reg <= select_data_channel_rgb_next; 
            rm_addr_base_reg <= rm_addr_base_next;
            rm_valid_reg <= rm_valid_next;
        end
             
    end


    always @(*) begin
        state_next = state_reg;
        arready_next = arready_reg;
        select_data_channel_rgb_next = select_data_channel_rgb_reg; 
        rm_addr_base_next = rm_addr_base_reg;
        rm_valid_next = rm_valid_reg;

        case (state_reg) 
            IDLE: begin
                if (ARVALID_i) begin
                    if ((ARADDR_i >= 'd0) && (ARADDR_i < 'd50176) ) begin
                        rm_addr_base_next = ARADDR_i;
                        select_data_channel_rgb_next = 3'b100;
                        rm_valid_next = 1;
                        state_next = RED_SETUP0;
                        arready_next = 1;
                        
                    end
                    else if ((ARADDR_i >= 'd50176) && (ARADDR_i < 'd100352)) begin
                        select_data_channel_rgb_next = 3'b010;
                        state_next = GREEN_SETUP;
                        arready_next = 1;
                        
                    end
                    else begin
                        select_data_channel_rgb_next = 3'b001;
                        state_next = BLUE_SETUP;
                        arready_next = 1;
                    end
                end

            end
            RED_SETUP0: begin
                arready_next = 0;
                if (rm_ready_i) begin
                    rm_valid_next = 0;
                    state_next = RED_SETUP1;
                end
            end
            RED_SETUP1: begin
                if (tlast_data_channel_rgb_i && tvalid_data_channel_rgb_i && tready_data_channel_rgb_i) begin
                    state_next = IDLE;
                    select_data_channel_rgb_next = 3'b000;
                end
            end
            GREEN_SETUP: begin
                arready_next = 0;
                if (tlast_data_channel_rgb_i && tvalid_data_channel_rgb_i && tready_data_channel_rgb_i) begin
                    state_next = IDLE;
                    select_data_channel_rgb_next = 3'b000;
                end
              
            end
            BLUE_SETUP: begin
                arready_next = 0;
                if (tlast_data_channel_rgb_i && tvalid_data_channel_rgb_i && tready_data_channel_rgb_i) begin
                    state_next = IDLE;
                    select_data_channel_rgb_next = 3'b000;
                end
            end

            default: begin
                state_next = IDLE;
            end
                
            
        endcase


    end

    assign ARREADY_o = arready_reg;
    assign select_data_channel_rgb_o = select_data_channel_rgb_reg;
    assign rm_addr_base_o = rm_addr_base_reg;
    assign rm_valid_o = rm_valid_reg;
endmodule
