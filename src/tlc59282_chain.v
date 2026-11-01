module tlc59282_chain #(
 parameter integer CLK_HZ=50000000,REFRESH_HZ=1000,N=48,REVERSE=0,SCLK_HZ=1000000
)(input wire clk,rst,input wire [N-1:0] bits,
 output reg sclk,sin,lat,bla,busy);
localparam HALF=(CLK_HZ/(2*SCLK_HZ)<1)?1:CLK_HZ/(2*SCLK_HZ);
localparam PERIOD=CLK_HZ/REFRESH_HZ;
reg [31:0] timer,pace;
reg [$clog2(N)-1:0] index;
reg [N-1:0] snapshot;
reg [2:0] state;
reg initialized;
always @(posedge clk) begin
 if(rst) begin
  sclk<=0;sin<=0;lat<=0;bla<=1;busy<=0;timer<=0;pace<=0;index<=0;snapshot<=0;state<=0;initialized<=0;
 end else begin
  if(timer<PERIOD) timer<=timer+1'b1;
  case(state)
   0:if(!initialized || timer>=PERIOD-1) begin
    snapshot<=bits;index<=0;busy<=1;timer<=0;state<=1;
   end
   1:begin
    sclk<=0;sin<=REVERSE?snapshot[N-1-index]:snapshot[index];pace<=0;state<=2;
   end
   2:if(pace==HALF-1) begin sclk<=1;pace<=0;state<=3;end else pace<=pace+1'b1;
   3:if(pace==HALF-1) begin
    sclk<=0;pace<=0;
    if(index==N-1) state<=4;
    else begin index<=index+1'b1;state<=1;end
   end else pace<=pace+1'b1;
   // LAT高期间锁存器透明；BLANK已独立，移位期间靠 lat=0 保持，不再需要用消隐遮挡。
   4:begin lat<=1;pace<=0;state<=5;end
   // 首帧锁存完成 → 拉低 BLANK 允许输出；之后每帧保持低，不再重复消隐。
   5:if(pace==HALF-1) begin lat<=0;bla<=0;busy<=0;initialized<=1;state<=0;end else pace<=pace+1'b1;
   default:begin state<=0;lat<=0;bla<=1;initialized<=0;end
  endcase
 end
end
endmodule
