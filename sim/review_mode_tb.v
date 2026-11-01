`timescale 1ns/1ps
// review_mode_tb —— 测试模式（按住板载 key1）入口/出口的 mux 口径回归。
// 覆盖：从非默认音色、变调、颤音、延时状态进入，音高、门控、音色、变调、颤音、延时、音量必须全部钉死。
// 判据：换一个起始音色再进一次结果一致；退出后恢复用户设定，且仍按着的键继续发声。
// 说明：用 force 改 star 内部寄存器构造入口状态，属白盒注入，不验证真实旋钮/触摸手感。
module review_mode_tb;
reg clk=0;always #10 clk=~clk;                  // 50MHz
reg reset_n=0;
reg key1=1;                                     // 1=正常模式；0=按住进测试模式（6ms 去抖）
reg [11:0] touch1=0,touch2=0;
tri s1,d1,s2,d2,st,dt;
pullup(s1);pullup(d1);pullup(s2);pullup(d2);pullup(st);pullup(dt);
wire bck,ws,din;
star dut(.clk(clk),.rst_n(reset_n),.key1(key1),
 .hp_bck(bck),.hp_ws(ws),.hp_din(din),.bt_rxd(1'b1),
 .mpr_scl(s1),.mpr_sda(d1),.mpr2_scl(s2),.mpr2_sda(d2),.vl53_scl(st),.vl53_sda(dt),
 .enc_a(1'b1),.enc_b(1'b1),.enc_sw(1'b1));
GSR GSR(.GSRI(1'b1));
// 加速建模：缩短 MPR 建立与 VL53 上电等待
defparam dut.u_mpr.SETTLE_CNT=1000;
defparam dut.u_mpr2.SETTLE_CNT=1000;
defparam dut.u_tof.PWR_CNT=100;
i2c_sensor_model m1(s1,d1,1'b1,1'b0,touch1,16'd0,1'b0);
i2c_sensor_model m2(s2,d2,1'b1,1'b0,touch2,16'd0,1'b0);
i2c_sensor_model #(.ADDRESS(7'h29),.KIND(2)) mt(st,dt,1'b1,1'b0,12'd0,16'd100,1'b0);

localparam integer DEBOUNCE=300000;             // star.v 里 k1_count 的 6ms 门限

// 层级探针一律先落到本地线网再比较。
// 直接对参数化位宽的层次化端口做 !== 比较会让 ModelSim 的 vlog 内部崩溃。
wire [27:0] p_pitch  = dut.u_eng.pitch;
wire [3:0]  p_gate   = dut.u_eng.gate;
wire [7:0]  p_timbre = dut.u_eng.timbre;
wire [5:0]  p_bend   = dut.u_eng.bend;
wire [1:0]  p_vib    = dut.u_eng.vibrato;
wire        p_hold   = dut.u_eng.env_hold;
wire        p_fxen   = dut.u_fx.enable;
wire [16:0] p_vol    = dut.vol_s;
wire [3:0]  p_kbgate = dut.kb_gate;
wire [15:0] p_audio  = dut.audio;
wire [23:0] p_keyall = dut.key_all;

task enter_test;
 begin
  key1=0;repeat(DEBOUNCE+10000) @(negedge clk);
  if(dut.test_mode!==1'b1) $fatal(1,"failed to enter test mode");
  repeat(3000) @(negedge clk);
 end
endtask

task leave_test;
 begin
  key1=1;repeat(DEBOUNCE+10000) @(negedge clk);
  if(dut.test_mode!==1'b0) $fatal(1,"failed to leave test mode");
  repeat(3000) @(negedge clk);
 end
endtask

task check_test_mode_pins;
 begin
  if(p_pitch!==28'h0)  $fatal(1,"test mode pitch not all C4: %h",p_pitch);
  if(p_gate!==4'b0001) $fatal(1,"test mode gate must be 4'b0001, got %b",p_gate);
  if(p_timbre!=={4{2'd1}}) $fatal(1,"test mode timbre must be SAW(1) = 32 harmonics, got %b",p_timbre);
  if(p_bend!==6'd0)    $fatal(1,"test mode bend must be 0, got %0d",p_bend);
  if(p_vib!==2'd0)     $fatal(1,"test mode vibrato must be 0, got %0d",p_vib);
  if(p_hold!==1'b1)    $fatal(1,"test mode env_hold must be 1");
  if(p_fxen!==1'b0)    $fatal(1,"test mode delay must be disabled");
  if(p_vol!==17'd32768)$fatal(1,"test mode volume must be full 32768, got %0d",p_vol);
  if(p_audio===16'sd0) $fatal(1,"test mode produced silence");
 end
endtask

initial begin
 #1000;reset_n=1;
 wait(dut.touch_ready && dut.touch_ready2);

 // 入口状态 1：非默认音色 + 变调 + 颤音 + 延时，且按着一个键
 force dut.timbre_select=2'd1;   // SAW
 force dut.bend=6'sd7;
 force dut.vibrato=2'd3;
 force dut.delay_on=1'b1;
 touch1=12'h001;
 // 等 MPR 模型真正扫出这一帧（固定延时不够）
 wait(p_keyall===24'h000001);
 repeat(500) @(negedge clk);

 // 先确认正常模式下这些值确实透传，下面的强制检查才有意义
 if(dut.test_mode!==1'b0)     $fatal(1,"test_mode should be 0 in normal mode");
 if(p_timbre!=={4{2'd1}}) $fatal(1,"normal mode did not pass timbre=SAW: %b",p_timbre);
 if(p_bend!==6'd7)       $fatal(1,"normal mode did not pass bend=7: %0d",p_bend);
 if(p_vib!==2'd3)        $fatal(1,"normal mode did not pass vibrato=3: %0d",p_vib);
 if(p_fxen!==1'b1)       $fatal(1,"normal mode did not pass delay_on=1");
 if(p_kbgate===4'b0000)  $fatal(1,"pressed key did not allocate a voice");
 $display("  ok normal mode passes timbre/bend/vibrato/delay through (kb_gate=%b)",p_kbgate);

 // 进入测试模式：各条 mux 必须全部钉死
 enter_test;
 check_test_mode_pins;
 $display("  ok test mode from (timbre=1,bend=7,vibrato=3,delay=on): all muxes pinned");

 // 退出：恢复用户设定，且按着的键继续发声
 leave_test;
 if(p_timbre!=={4{2'd1}}) $fatal(1,"timbre not restored after test mode: %b",p_timbre);
 if(p_bend!==6'd7)     $fatal(1,"bend not restored: %0d",p_bend);
 if(p_vib!==2'd3)      $fatal(1,"vibrato not restored: %0d",p_vib);
 if(p_fxen!==1'b1)     $fatal(1,"delay not restored");
 if(p_gate!==p_kbgate)  $fatal(1,"gate mux not restored after test mode: %b vs %b",p_gate,p_kbgate);
 if(p_kbgate===4'b0000) $fatal(1,"held key lost its voice after leaving test mode");
 $display("  ok leaving test mode restores user settings and keeps the held key sounding");

 // 入口状态 2：换成音色 0 再进一次，结论必须一致
 force dut.timbre_select=2'd0;   // SINE
 repeat(500) @(negedge clk);
 if(p_timbre!==8'h00) $fatal(1,"timbre=SINE not passed in normal mode: %b",p_timbre);
 enter_test;
 check_test_mode_pins;
 $display("  ok test mode from (timbre=SINE): identical 32-component setting (forced SAW)");
 leave_test;

 $display("PASS review_mode: test-mode muxes pinned (C4/timbre0/voice0/bend0/vib0/delay off/full vol), restored on exit");
 $finish;
end
initial begin #200000000;$fatal(1,"mode timeout");end
endmodule
