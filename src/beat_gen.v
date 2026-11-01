module beat_gen #(
 parameter integer CLK_HZ = 50_000_000
)(
 input  wire clk,
 input  wire rst,
 input  wire [2:0] tempo_idx,      // 0..5 → 60/80/100/120/160/200 BPM
 output reg  t16_tick,             // 1 clk 宽的脉冲：一个 1/16 音符结束
 output reg  t16_half              // 1 clk 宽的脉冲：一个 1/16 音符走到一半
);
localparam integer T16_60  = (CLK_HZ*15)/60  - 1;
localparam integer T16_80  = (CLK_HZ*15)/80  - 1;
localparam integer T16_100 = (CLK_HZ*15)/100 - 1;
localparam integer T16_120 = (CLK_HZ*15)/120 - 1;
localparam integer T16_160 = (CLK_HZ*15)/160 - 1;
localparam integer T16_200 = (CLK_HZ*15)/200 - 1;
localparam [24:0] P_60  = T16_60;           //  60      12_500_000  @50MHz
localparam [24:0] P_80  = T16_80;           //  80       9_375_000  @50MHz
localparam [24:0] P_100 = T16_100;          // 100       7_500_000  @50MHz
localparam [24:0] P_120 = T16_120;          // 120       6_250_000  @50MHz
localparam [24:0] P_160 = T16_160;          // 160       4_687_500  @50MHz
localparam [24:0] P_200 = T16_200;          // 200       3_750_000  @50MHz

reg [24:0] per16;
reg [24:0] per16h;            // per16 的一半，用来出"半格"脉冲
always @* begin
 case(tempo_idx)
  3'd0:    begin per16=P_60;  per16h=P_60 >>1; end
  3'd1:    begin per16=P_80;  per16h=P_80 >>1; end
  3'd2:    begin per16=P_100; per16h=P_100>>1; end
  3'd4:    begin per16=P_160; per16h=P_160>>1; end
  3'd5:    begin per16=P_200; per16h=P_200>>1; end
  default: begin per16=P_120; per16h=P_120>>1; end // 3 和越界落到 120BPM
 endcase
end
reg [24:0] cnt;
always @(posedge clk) begin
 if(rst) begin
  cnt<=25'd0;t16_tick<=1'b0;t16_half<=1'b0;
 end else begin
  t16_tick <=1'b0;            // 默认低，只在计数到顶那一拍抬起
  t16_half <=1'b0;
  if(cnt>=per16) begin
   cnt      <= 25'd0;
   t16_tick <= 1'b1;
  end else begin
   cnt<=cnt+25'd1;
   if(cnt==per16h) t16_half<=1'b1;
  end
 end
end
endmodule
