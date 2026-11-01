module uart_rx #(
 parameter integer CLK_HZ=50_000_000,
 parameter integer BAUD  =115200
)(
 input  wire clk,
 input  wire rst,
 input  wire rx,
 output reg  [7:0] data,      // 收到的字节
 output reg        valid      // 1 个 clk 宽的脉冲
);
localparam integer BDIV=(CLK_HZ+BAUD/2)/BAUD;
localparam integer HALF=BDIV/2;

// 输入同步（异步信号打两拍）
(* syn_preserve=1 *) reg [1:0] sync=2'b11;
always @(posedge clk) sync<={sync[0],rx};
wire rxq=sync[1];

localparam [1:0] S_IDLE=2'd0,S_START=2'd1,S_DATA=2'd2,S_STOP=2'd3;
reg [1:0] st;
reg [15:0] cnt;
reg [2:0]  bit_i;
reg [7:0]  sh;
always @(posedge clk) begin
 if(rst) begin st<=S_IDLE;cnt<=0;bit_i<=0;sh<=0;data<=0;valid<=0;end
 else begin
  valid<=1'b0;
  case(st)
   S_IDLE: begin
    cnt<=0;bit_i<=0;
    if(!rxq) st<=S_START;          // 检测起始位下降沿
   end
   S_START: begin
    if(cnt>=HALF-1) begin         // 半位后确认还是低，才算真起始
     cnt<=0;
     if(!rxq) st<=S_DATA; else st<=S_IDLE;
    end else cnt<=cnt+1'b1;
   end
   S_DATA: begin
    if(cnt>=BDIV-1) begin
     cnt<=0;
     sh<={rxq,sh[7:1]};          // LSB 先到
     if(bit_i==3'd7) st<=S_STOP;
     else bit_i<=bit_i+1'b1;
    end else cnt<=cnt+1'b1;
   end
   S_STOP: begin
    if(cnt>=BDIV-1) begin
     cnt<=0;
     data<=sh;
     valid<=rxq; // 2026-10-23 修改批注：停止位必须为高，丢弃帧错误/BREAK，避免交付伪字节。
     st<=S_IDLE;
    end else cnt<=cnt+1'b1;
   end
  endcase
 end
end
endmodule
