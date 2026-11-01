`timescale 1ns/1ps
// TLC59282 移位链验证：复位消隐、48 位帧长、快照顺序、连续两帧。
module review_led_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;
 reg [47:0] bits=48'h9123456789ab;
 wire sclk,sin,lat,bla,busy;
 tlc59282_chain dut(clk,rst,bits,sclk,sin,lat,bla,busy);
 reg [47:0] shifted=0,expected;
 integer count=0,frames=0,i;
 always @(posedge sclk) if(!rst) begin
  shifted={shifted[46:0],sin}; count=count+1;
 end
 always @(negedge lat) if(!rst) begin
  if(count!=48) $fatal(1,"LED frame length %0d",count);
  if(shifted!==expected) $fatal(1,"LED snapshot/order mismatch");
  frames=frames+1; count=0; expected=0;
 end
 initial begin
  for(i=0;i<48;i=i+1) expected[47-i]=bits[i];
  repeat(10) @(negedge clk);
  if(bla!==1) $fatal(1,"reset must blank outputs");
  rst=0;
  wait(busy); @(negedge clk); bits=0;
  wait(frames==2);
  $display("PASS review_led: reset blank, 48 bits, snapshot, order, two frames");
  $finish;
 end
 initial begin #5000000; $fatal(1,"LED timeout"); end
endmodule
