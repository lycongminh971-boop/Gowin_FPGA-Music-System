`timescale 1ns/1ps
// 顶层 LED 接线：按键灯、指引目标灯、完成熄灭、停止后恢复按键灯。
// 白盒注入 led_map 的输入，只验证映射与优先级，不涉及真实触摸和灯色。
module review_guide_led_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst_n=0;
 star dut(.clk(clk),.rst_n(rst_n),.key1(1'b1),.bt_rxd(1'b1),
  .enc_a(1'b1),.enc_b(1'b1),.enc_sw(1'b1));
 GSR GSR(.GSRI(1'b1));
 wire [47:0] lamps=dut.led_bits;
 initial begin
  repeat(10) @(negedge clk); rst_n=1;
  repeat(51000) @(negedge clk);
  // key3 按下 → bits[6]
  force dut.key_all=24'h000008;
  force dut.g_busy=0; force dut.g_done=0; force dut.g_valid=0;
  #100; if(lamps!==48'h40) $fatal(1,"key3 press not routed to bits[6]");
  // 指引目标 key7 → bits[15]，且指引期间按键灯让位
  force dut.g_busy=1; force dut.g_valid=1; force dut.g_targets=24'h000080;
  #100; if(lamps!==(48'd1<<15)) $fatal(1,"guide key7 not routed to physical driver");
  // 高音区 key23 → bits[47]
  force dut.g_targets=24'h800000;
  #100; if(lamps!==(48'd1<<47)) $fatal(1,"guide key23 mapping");
  // 完成：目标灯和按键灯都熄灭
  force dut.g_busy=0; force dut.g_valid=0; force dut.g_done=1;
  #100; if(lamps!==0) $fatal(1,"completion must extinguish lamps");
  // 停止后恢复按键灯
  force dut.g_done=0;
  #100; if(lamps!==48'h40) $fatal(1,"STOP must restore press lamps");
  release dut.g_busy; release dut.g_done; release dut.g_valid; release dut.g_targets;
  release dut.key_all;
  $display("PASS review_guide_led: press, guide routing, completion, stop restore");
  $finish;
 end
 initial begin #5000000; $fatal(1,"guide LED timeout"); end
endmodule
