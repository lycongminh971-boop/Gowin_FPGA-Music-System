`timescale 1ns/1ps
// audio_tx_tb.v —— I2S 发送器两种模式的逐位解码回读。
// 覆盖：默认模式按 bck 逐位拼 16 位字；I2S_MODE=1 时 WS 后空 1 个 bck 再取 MSB。
// 判据：两模式解出字须等于 sample_frame；I2S 填充位必须为 0，各模式不少于 20 字。
module audio_tx_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1;
reg [15:0] sample=16'h8123;
wire tick0,b0,w0,d0,tick1,b1,w1,d1;
audio_tx tx0(clk,rst,sample,tick0,b0,w0,d0);
audio_tx #(.I2S_MODE(1)) tx1(clk,rst,sample,tick1,b1,w1,d1);
integer n0=0,n1=0,words0=0,words1=0;
reg [15:0] a=0,b=0,e0,e1;
always @(posedge b0) if(!rst) begin
 if(n0==0) e0=tx0.sample_frame;
 a={a[14:0],d0};
 if(n0==15) begin
  if(a!==e0) $fatal(1,"LSBJ word mismatch");
  words0=words0+1;n0=0;
 end else n0=n0+1;
end
always @(posedge b1) if(!rst) begin
 if(n1==0) begin
  e1=tx1.sample_frame;
  if(d1!==0) $fatal(1,"I2S missing WS-to-MSB delay");
 end
 if(n1>=1 && n1<=16) b={b[14:0],d1};
 if(n1==16 && b!==e1) $fatal(1,"I2S word mismatch");
 if(n1>16 && d1!==0) $fatal(1,"I2S padding mismatch");
 if(n1==31) begin words1=words1+1;n1=0;end
 else n1=n1+1;
end
initial begin
 #1000;rst=0;
 #90000;sample=16'h7abc;
 #90000;sample=16'h0001;
 #90000;
 if(words0<20 || words1<20) $fatal(1,"missing audio words");
 $display("PASS LSBJ and I2S decoded words %0d %0d",words0,words1);
 $finish;
end
endmodule
