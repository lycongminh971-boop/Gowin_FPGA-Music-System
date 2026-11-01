module uart_tx #(
 parameter integer CLK_HZ=50_000_000,
 parameter integer BAUD  =115200
)(
 input  wire clk,
 input  wire rst,
 input  wire send,        // 1 个 clk 脉冲：启动一次发送（busy 时必须忽略）
 input  wire [7:0] data,
 output reg  tx,          // 空闲为高
 output reg  busy
);
localparam integer BDIV=(CLK_HZ+BAUD/2)/BAUD;
reg [15:0] cnt;
reg [3:0]  bit_i;        // 0=起始位 1..8=数据 9=停止位
reg [7:0]  sh;
always @(posedge clk) begin
 if(rst) begin tx<=1'b1;busy<=1'b0;cnt<=0;bit_i<=0;sh<=0;end
 else begin
  if(!busy) begin
   tx<=1'b1;cnt<=0;
   if(send) begin busy<=1'b1;sh<=data;bit_i<=4'd0;tx<=1'b0;end   // 起始位
  end else begin
   if(cnt>=BDIV-1) begin
    cnt<=0;
    case(bit_i)
     4'd0,4'd1,4'd2,4'd3,4'd4,4'd5,4'd6:
       begin tx<=sh[0];sh<={1'b0,sh[7:1]};bit_i<=bit_i+1'b1;end
     4'd7: begin tx<=sh[0];sh<=8'd0;bit_i<=4'd8;end               // 第 8 个数据位
     4'd8: begin tx<=1'b1;bit_i<=4'd9;end                         // ֹͣλ
     default: begin tx<=1'b1;busy<=1'b0;end                       // 停止位结束
    endcase
   end else cnt<=cnt+1'b1;
  end
 end
end
endmodule
