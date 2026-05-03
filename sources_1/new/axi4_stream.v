`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/03/2026 05:35:00 PM
// Design Name: 
// Module Name: axi4_stream
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
module axi4_stream#(
    parameter DATA_WIDTH_BYTE = 1, // byte unit, 1: 8bit, 2: 16bit, 4: 32bit, 8: 64bit
    parameter SELECT_INTERFACE = 0, // 0: master interface, 1: slave interface
    parameter SIZE_FIFO = 8 // 2^SIZE_FIFO is the depth of FIFO
)(
    //generate port
    input                           aclk_i,
    input                           aresetn_i,
    /////////////////////////////////////////////////
    //master interface port
    /////////////////////////////////////////////////
    output                          m_tvalid_o,
    input                           m_tready_i,
    output  [DATA_WIDTH_BYTE*8-1:0] m_tdata_o,
    output  [DATA_WIDTH_BYTE-1:0]   m_tstrb_o,
    output  [DATA_WIDTH_BYTE-1:0]   m_tkeep_o,
    output                          m_tlast_o,
    output                          m_tid_o,

    //user master interface port
    output                          user_m_busy_o,
    input                           user_m_wr_data_i,
    input  [DATA_WIDTH_BYTE*8-1:0]  user_m_data_i,
    input  [DATA_WIDTH_BYTE-1:0]    user_m_tstrb_i,
    input  [DATA_WIDTH_BYTE-1:0]    user_m_tkeep_i,
    input                           user_m_tlast_i,
    input                           user_m_tid_i,
    /////////////////////////////////////////////////

    /////////////////////////////////////////////////
    //slave interface port
    /////////////////////////////////////////////////
    input                           s_tvalid_i,
    output                          s_tready_o,
    input  [DATA_WIDTH_BYTE*8-1:0]  s_tdata_i,
    input  [DATA_WIDTH_BYTE-1:0]    s_tstrb_i,
    input  [DATA_WIDTH_BYTE-1:0]    s_tkeep_i,
    input                           s_tlast_i,
    input                           s_tid_i,

    //user slave interface port
    output                          user_s_ready_o,
    input                           user_s_rd_data_i,
    output  [DATA_WIDTH_BYTE*8-1:0] user_s_data_o,
    output  [DATA_WIDTH_BYTE-1:0]   user_s_tstrb_o,
    output  [DATA_WIDTH_BYTE-1:0]   user_s_tkeep_o,
    output                          user_s_tlast_o,
    output                          user_s_tid_o
    /////////////////////////////////////////////////
    );

    generate
        //master interface
        if (SELECT_INTERFACE == 0) begin
            
            wire empty_i, full_i, rd_fifo_o;

            coordinator_master#(
                .DATA_WIDTH_BYTE(DATA_WIDTH_BYTE)
            )coordinator_master_uut(
                //port generate
                .m_tvalid_o(m_tvalid_o),
                .m_tready_i(m_tready_i),
                .user_m_busy_o(user_m_busy_o),
                .empty_i(empty_i),
                .full_i(full_i),
                .rd_fifo_o(rd_fifo_o)
            );

            wire  [DATA_WIDTH_BYTE*8-1:0] wire_tdata;
            wire  [DATA_WIDTH_BYTE-1:0]   wire_tstrb;
            wire  [DATA_WIDTH_BYTE-1:0]   wire_tkeep;
            wire                          wire_tlast;

            // register_DFF #(
            //     .SIZE_BITS(1 + DATA_WIDTH_BYTE + DATA_WIDTH_BYTE + (DATA_WIDTH_BYTE*8))
            // ) stage_delay_data (
            //     .clk_i(aclk_i),
            //     .resetn_i(aresetn_i),
            //     .D_i({user_m_tlast_i, user_m_tkeep_i, user_m_tstrb_i, user_m_data_i}),
            //     .Q_o({wire_tlast, wire_tkeep, wire_tstrb, wire_tdata})
            // );

            fifo_unit #(.ADDR_WIDTH(SIZE_FIFO), .DATA_WIDTH(2 + DATA_WIDTH_BYTE + DATA_WIDTH_BYTE + (DATA_WIDTH_BYTE*8))) buffer_uut(
                .clk(aclk_i), 
                .reset_n(aresetn_i),
                .wr(user_m_wr_data_i && !user_m_busy_o), 
                .rd(rd_fifo_o),
                // .wr_ptr(),
                // .rd_ptr(),
                .w_data({user_m_tid_i, user_m_tlast_i, user_m_tkeep_i, user_m_tstrb_i, user_m_data_i}),                //writing data
                .r_data({m_tid_o, m_tlast_o, m_tkeep_o, m_tstrb_o, m_tdata_o}),                    //reading data
                .full(full_i),
                .empty(empty_i)
            );

            
        end

        //slave interface
        else if (SELECT_INTERFACE == 1) begin
            wire empty_i, full_i, wr_fifo_o;

            coordinator_slave#(
                .DATA_WIDTH_BYTE(DATA_WIDTH_BYTE)
            )coordinator_slave_uut(
                //port generate
                .s_tvalid_i(s_tvalid_i),
                .s_tready_o(s_tready_o),
                .user_s_ready_o(user_s_ready_o),
                .empty_i(empty_i),
                .full_i(full_i),
                .wr_fifo_o(wr_fifo_o)
            );

            

            fifo_unit #(.ADDR_WIDTH(SIZE_FIFO), .DATA_WIDTH(2 + DATA_WIDTH_BYTE + DATA_WIDTH_BYTE + (DATA_WIDTH_BYTE*8))) buffer_uut(
                .clk(aclk_i), 
                .reset_n(aresetn_i),
                .wr(wr_fifo_o), 
                .rd(user_s_rd_data_i && user_s_ready_o),
                // .wr_ptr(),
                // .rd_ptr(),
                .w_data({s_tid_i, s_tlast_i, s_tkeep_i, s_tstrb_i, s_tdata_i}),                                       //writing data
                .r_data({user_s_tid_o, user_s_tlast_o, user_s_tkeep_o, user_s_tstrb_o, user_s_data_o}),                    //reading data
                .full(full_i),
                .empty(empty_i)
            );
            
        end
    endgenerate



endmodule


module coordinator_master#(
    parameter DATA_WIDTH_BYTE = 2
)(
    /////////////////////////////////////////////////
    //port master interface
    /////////////////////////////////////////////////
    output                          m_tvalid_o,
    input                           m_tready_i,
    output                          user_m_busy_o,
    //port FIFO interface
    input                           empty_i,
    input                           full_i,
    output                          rd_fifo_o
);

    assign m_tvalid_o = !empty_i;
    assign rd_fifo_o = (m_tvalid_o == 1 && m_tready_i == 1) ? 1'b1 : 1'b0;
    assign user_m_busy_o = full_i;

endmodule


module coordinator_slave#(
    parameter DATA_WIDTH_BYTE = 2
)(
    /////////////////////////////////////////////////
    //port slave interface
    /////////////////////////////////////////////////
    input                           s_tvalid_i,
    output                          s_tready_o,
    
    output                          user_s_ready_o,


    //port FIFO interface
    input                           empty_i,
    input                           full_i,
    output                          wr_fifo_o

);
    assign s_tready_o = (!full_i && s_tvalid_i == 1) ? 1'b1 : 1'b0;
    assign wr_fifo_o = (s_tvalid_i == 1 && s_tready_o == 1) ? 1'b1 : 1'b0;
    assign user_s_ready_o = !empty_i;

endmodule


// module decoder_1to2_axis_interface #(
//     parameter DATA_WIDTH_BYTE = 1
// )(
//     //master interface port (Input từ Hyperbus FIFO)
//     input                           m_tvalid_i,
//     output                          m_tready_o,
//     input  [DATA_WIDTH_BYTE*8-1:0]  m_tdata_i,
//     input  [DATA_WIDTH_BYTE-1:0]    m_tstrb_i,
//     input  [DATA_WIDTH_BYTE-1:0]    m_tkeep_i,
//     input                           m_tlast_i,
//     input                           m_tid_i,

//     //slave interface port 0 (Output ra Accel AR0)
//     output                          s_tvalid0_o,
//     input                           s_tready0_i,
//     output [DATA_WIDTH_BYTE*8-1:0]  s_tdata0_o,
//     output [DATA_WIDTH_BYTE-1:0]    s_tstrb0_o,
//     output [DATA_WIDTH_BYTE-1:0]    s_tkeep0_o,
//     output                          s_tlast0_o,

//     //slave interface port 1 (Output ra Accel AR1)
//     output                          s_tvalid1_o,
//     input                           s_tready1_i,
//     output [DATA_WIDTH_BYTE*8-1:0]  s_tdata1_o,
//     output [DATA_WIDTH_BYTE-1:0]    s_tstrb1_o,
//     output [DATA_WIDTH_BYTE-1:0]    s_tkeep1_o,
//     output                          s_tlast1_o
// );

//     // ==========================================
//     // DEMUX LOGIC (Dựa vào m_tid_i)
//     // ==========================================

//     // 1. Phân luồng TVALID (Chiều đi tới Accel)
//     // Chỉ báo Valid cho Kênh 0 nếu ID = 0, và Kênh 1 nếu ID = 1
//     assign s_tvalid0_o = m_tvalid_i & (m_tid_i == 1'b0);
//     assign s_tvalid1_o = m_tvalid_i & (m_tid_i == 1'b1);

//     // 2. Phân luồng TREADY (Chiều ngược lại từ Accel về FIFO)
//     // Master (FIFO) chỉ thấy trạng thái Ready của kênh đang được chọn bởi ID
//     assign m_tready_o  = (m_tid_i == 1'b0) ? s_tready0_i : s_tready1_i;

//     // 3. Broadcast Data & Sideband Signals (Tiết kiệm Logic)
//     assign s_tdata0_o  = m_tdata_i;
//     assign s_tdata1_o  = m_tdata_i;

//     assign s_tstrb0_o  = m_tstrb_i;
//     assign s_tstrb1_o  = m_tstrb_i;

//     assign s_tkeep0_o  = m_tkeep_i;
//     assign s_tkeep1_o  = m_tkeep_i;

//     assign s_tlast0_o  = m_tlast_i;
//     assign s_tlast1_o  = m_tlast_i;

// endmodule




















































// module register_DFF#(
//     parameter SIZE_BITS = 32
// )(  
//     input                           clk_i,
//     input                           resetn_i,
//     input       [SIZE_BITS-1:0]    D_i,

//     output  reg [SIZE_BITS-1:0]    Q_o
// );
//     always @(posedge clk_i, negedge resetn_i) begin
//         if (~resetn_i) begin
//             Q_o <= 0;
//         end
//         else begin
//             Q_o <= D_i;
//         end
//     end

// endmodule




//// fifo

// fifo_unit #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) uut(
//         .clk(clk), 
//         .reset_n(reset_n),
//         .wr(wr), 
//         .rd(rd),
//         .wr_ptr(wr_ptr),
//         .rd_ptr(rd_ptr),
//         .w_data(w_data),
//         .r_data(r_data),

//         .full(full),
//         .empty(empty)
//     );

module fifo_unit #(parameter ADDR_WIDTH = 3, DATA_WIDTH = 8)(
    input clk, reset_n,
    input wr, rd,
    output [ADDR_WIDTH - 1 : 0] wr_ptr, rd_ptr,

    input [DATA_WIDTH - 1 : 0] w_data, //writing data
    output [DATA_WIDTH - 1 : 0] r_data, //reading data

    output full, empty

    );

    //signal
    wire [ADDR_WIDTH - 1 : 0] w_addr, r_addr;

    //instantiate registers file
    register_file #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH))
        reg_file_unit(
            .clk(clk),
            .w_en(~full & wr),

            .r_addr(r_addr), //reading address
            .w_addr(w_addr), //writing address

            .w_data(w_data), //writing data
            .r_data(r_data) //reading data
        
        );

    //instantiate fifo ctrl
    fifo_ctrl #(.ADDR_WIDTH(ADDR_WIDTH))
        fifo_ctrl(
            .clk(clk), 
            .reset_n(reset_n),
            .wr(wr), 
            .rd(rd),

            .full(full),
            .empty(empty),

            .w_addr(w_addr),
            .r_addr(r_addr)
        );

    assign wr_ptr = w_addr;
    assign rd_ptr = r_addr;
    

endmodule


module register_file #(parameter ADDR_WIDTH = 3, DATA_WIDTH = 8)(
    input clk,
    input w_en,

    input [ADDR_WIDTH - 1 : 0] r_addr, //reading address
    input [ADDR_WIDTH - 1 : 0] w_addr, //writing address

    input [DATA_WIDTH - 1 : 0] w_data, //writing data
    output [DATA_WIDTH - 1 : 0] r_data //reading data
    );

    //memory buffer
    reg [DATA_WIDTH -1 : 0] memory [0 : 2 ** ADDR_WIDTH - 1];

    //wire operation
    always @(posedge clk) begin
        if (w_en) memory[w_addr] <= w_data;
        
    end

    //read operation
    assign r_data = memory[r_addr];

endmodule



module fifo_ctrl #(parameter ADDR_WIDTH = 3)(
    input clk, reset_n,
    input wr, rd,

    output reg full, empty,

    output [ADDR_WIDTH - 1 : 0] w_addr,
    output [ADDR_WIDTH - 1 : 0] r_addr
    );

    //variable sequential
    reg [ADDR_WIDTH - 1 : 0] w_ptr, w_ptr_next;
    reg [ADDR_WIDTH - 1 : 0] r_ptr, r_ptr_next;
 
    reg full_next, empty_next;


    // sequential circuit
    always @(posedge clk, negedge reset_n) begin
        if(~reset_n)begin
            w_ptr <= 'b0;
            r_ptr <= 'b0;
            full <= 1'b0;
            empty <= 1'b1;
        end

        else begin
            w_ptr <= w_ptr_next;
            r_ptr <= r_ptr_next;
            full <= full_next;
            empty <= empty_next;
        end

    end

    //combi circuit
    always @(*)begin
        //default
        w_ptr_next = w_ptr;
        r_ptr_next = r_ptr;
        full_next = full;
        empty_next = empty;

        case ({wr, rd})
            2'b01: begin    //read
                if(~empty)begin
                    r_ptr_next = r_ptr + 1;
                    full_next = 1'b0;
                    if(r_ptr_next == w_ptr)begin
                        empty_next = 1'b1;
                    end
                end
            end

            2'b10: begin    //write
                if(~full)begin
                    w_ptr_next = w_ptr + 1;
                    empty_next = 1'b0;
                    if(w_ptr_next == r_ptr)begin
                        full_next = 1'b1;
                    end
                end
            end

            2'b11: begin    //read & write
                if(empty)begin
                    w_ptr_next = w_ptr;
                    r_ptr_next = r_ptr;
                end

                else begin
                    w_ptr_next = w_ptr + 1;
                    r_ptr_next = r_ptr + 1;
                end
            end

            default: ; // 2'b00
        endcase


    end

    //output
    assign w_addr = w_ptr;
    assign r_addr = r_ptr;

endmodule

