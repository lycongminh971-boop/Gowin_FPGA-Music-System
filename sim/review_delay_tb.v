`timescale 1ns/1ps
// review_delay_tb.v —— 音频延迟线：干声混音、8 拍回波、反馈衰减与直通。
// 覆盖：脉冲 16000 先得半幅 8000，8 拍后回波 8000，再经反馈衰减到 4000。
// 判据：out_valid 拉高后 dout 须与期望值严格相等。
// 注意：AW=3 即 8 字缓冲；enable=0 时 dout 直通 din。
module review_delay_tb;
GSR GSR(.GSRI(1'b1));
reg clk=0;always #10 clk=~clk;
reg rst=1,valid=0,enable=1;
reg signed [15:0] din=0;
wire signed [15:0] dout;
wire out_valid;
audio_delay #(.AW(3)) dut(clk,rst,valid,enable,din,dout,out_valid);
integer i;
task send;
 input signed [15:0] value;
 input signed [15:0] expected;
 begin
  @(negedge clk);din=value;valid=1;
  @(negedge clk);valid=0;
  wait(out_valid);#1;
  if(dout!==expected) $fatal(1,"delay got %0d expected %0d",dout,expected);
  repeat(8) @(negedge clk);
 end
endtask
initial begin
 repeat(10) @(negedge clk);rst=0;
 send(16000,8000);
 for(i=1;i<8;i=i+1) send(0,0);
 send(0,8000);
 for(i=1;i<8;i=i+1) send(0,0);
 send(0,4000);
 enable=0;send(-30000,-30000);
 $display("PASS review_delay: dry, delayed impulse, feedback, bypass, initialized RAM");
 $finish;
end
endmodule
