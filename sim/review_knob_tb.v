`timescale 1ns/1ps
// review_knob_tb —— 旋钮两态菜单（浏览/调整）状态机回归。
// 覆盖：上电默认（浏览、TONE、SAW）、浏览态换项与首尾循环、调整态改值与上下限夹紧、短按进出。
// 判据：一格只步进一次、一按只出一次事件、按压与旋转同拍时按压优先、切项后参数保留。
// 另测：测试模式下菜单冻结、参数保留，退出仍为浏览态。
module review_knob_tb;
reg clk=0;always #10 clk=~clk;
reg reset_n=0,key1=1;
reg enc_a=1,enc_b=1,enc_sw=1;
reg [11:0] touch1=0,touch2=0;
tri s1,d1,s2,d2,st,dt;
pullup(s1);pullup(d1);pullup(s2);pullup(d2);pullup(st);pullup(dt);
wire bck,ws,din;
star dut(.clk(clk),.rst_n(reset_n),.key1(key1),
 .hp_bck(bck),.hp_ws(ws),.hp_din(din),.bt_rxd(1'b1),
 .mpr_scl(s1),.mpr_sda(d1),.mpr2_scl(s2),.mpr2_sda(d2),.vl53_scl(st),.vl53_sda(dt),
 .enc_a(enc_a),.enc_b(enc_b),.enc_sw(enc_sw));
GSR GSR(.GSRI(1'b1));
defparam dut.u_mpr.SETTLE_CNT=1000;
defparam dut.u_mpr2.SETTLE_CNT=1000;
defparam dut.u_tof.PWR_CNT=100;
defparam dut.u_enc.FILT_US=2;    // FILT_CYC = 50*2 = 100 拍
defparam dut.u_enc.SW_MS=1;      // SW_CYC  = 50000 拍 = 1ms
i2c_sensor_model m1(s1,d1,1'b1,1'b0,touch1,16'd0,1'b0);
i2c_sensor_model m2(s2,d2,1'b1,1'b0,touch2,16'd0,1'b0);
i2c_sensor_model #(.ADDRESS(7'h29),.KIND(2)) mt(st,dt,1'b1,1'b0,12'd0,16'd100,1'b0);

localparam integer SETTLE=300;    // 每个四分之一步要稳定 > FILT_CYC(100)
localparam integer SW_HOLD=60000; // 每次按压/松开 > SW_CYC(50000)

// 层级探针：先落到本地线网再比较（直接对层次化端口做 !== 会让 vlog 内部崩溃）
wire [2:0]  p_item   = dut.item;
wire        p_mode   = dut.select_mode;
wire [1:0]  p_timbre = dut.timbre_select;
wire [5:0]  p_bend   = dut.bend;
wire [1:0]  p_vib    = dut.vibrato;
wire        p_delay  = dut.delay_on;
wire        p_test   = dut.test_mode;

// 相位映射与 ec11_decode 的 g2p 相反：相位 p ↔ {A,B}
//   0=00 1=01 2=11 3=10 ；顺时针 = 相位 +1
integer gs=2;
task set_ph;
 input integer p;
 begin
  gs=p;
  enc_a=(p>=2);
  enc_b=(p==1)||(p==2);
  repeat(SETTLE) @(negedge clk);
 end
endtask
task rot_cw;                       // 顺时针 n 格，每格 2 个四分之一步
 input integer n;
 integer i;
 begin for(i=0;i<n;i=i+1) begin set_ph((gs+1)%4); set_ph((gs+1)%4); end end
endtask
task rot_ccw;
 input integer n;
 integer i;
 begin for(i=0;i<n;i=i+1) begin set_ph((gs+3)%4); set_ph((gs+3)%4); end end
endtask
task press;                        // 按下 → 松开
 begin
  enc_sw=0;repeat(SW_HOLD) @(negedge clk);
  enc_sw=1;repeat(SW_HOLD) @(negedge clk);
 end
endtask
task chk_item;
 input [2:0] want;
 begin if(p_item!==want) $fatal(1,"item=%0d want=%0d",p_item,want); end
endtask

initial begin
 #1000;reset_n=1;
 wait(dut.touch_ready && dut.touch_ready2);
 set_ph(2);
 repeat(200) @(negedge clk);

 // 上电默认：浏览 + TONE + SAW
 if(p_mode!==1'b0)  $fatal(1,"power-on must be BROWSE");
 chk_item(2'd0);
 if(p_timbre!==2'd1) $fatal(1,"power-on timbre must be SAW(1), got %0d",p_timbre);
 if(p_bend!==6'sd0 || p_vib!==2'd0 || p_delay!==1'b0) $fatal(1,"power-on params not default");
 $display("  ok power-on: BROWSE / TONE / SAW / bend0 vib0 delay off");

 // 半格不产生事件
 set_ph((gs+1)%4);              // 只走一个四分之一步
 set_ph((gs+3)%4);              // 退回去
 chk_item(2'd0);
 $display("  ok half-detent produced no step");

// 浏览态：切换编辑项，首尾循环（共 4 项）
rot_cw(1);  chk_item(3'd1);    // 音色 -> 变调
rot_ccw(1); chk_item(3'd0);    // 变调 -> 音色
rot_ccw(1); chk_item(3'd3);    // 音色 -> 延时（逆时针绕到最后一项）
rot_cw(1);  chk_item(3'd0);    // 延时 -> 音色
rot_cw(3);  chk_item(3'd3);    // 一路走到延时
rot_cw(1);  chk_item(3'd0);    // 延时 -> 音色，回到 TONE 测试起点
$display("  ok browse rotation cycles TONE/BEND/VIB/DELAY with wrap-around");
 if(p_timbre!==2'd1) $fatal(1,"browse rotation must not change parameters");

 // TONE：进入调整、上下限夹紧、确认退出
 press();                       // 进入 EDIT
 if(p_mode!==1'b1) $fatal(1,"press did not enter EDIT");
 if(p_item!==2'd0) $fatal(1,"entering EDIT changed the item");
 rot_cw(1);  if(p_timbre!==2'd2) $fatal(1,"TONE up: want SQUARE(2) got %0d",p_timbre);
 rot_cw(1);  if(p_timbre!==2'd3) $fatal(1,"TONE up: want TRI(3) got %0d",p_timbre);
 rot_cw(1);  if(p_timbre!==2'd3) $fatal(1,"TONE must clamp at TRI, got %0d",p_timbre);
 rot_ccw(3); if(p_timbre!==2'd0) $fatal(1,"TONE down: want SINE(0) got %0d",p_timbre);
 rot_ccw(1); if(p_timbre!==2'd0) $fatal(1,"TONE must clamp at SINE, got %0d",p_timbre);
 press();                       // 确认返回浏览
 if(p_mode!==1'b0) $fatal(1,"confirm did not return to BROWSE");
 if(p_timbre!==2'd0) $fatal(1,"confirm must keep the value");
 $display("  ok TONE: enter/up/down/clamp/confirm, value kept");

 // BEND：切项后参数保留，上下限 ±12
 rot_cw(1); chk_item(2'd1);
 if(p_timbre!==2'd0) $fatal(1,"switching item lost the timbre setting");
 press();
 rot_cw(12); if(p_bend!==6'sd12)  $fatal(1,"BEND up: want +12 got %0d",p_bend);
 rot_cw(1);  if(p_bend!==6'sd12)  $fatal(1,"BEND must clamp at +12, got %0d",p_bend);
 rot_ccw(24);if(p_bend!==-6'sd12) $fatal(1,"BEND down: want -12 got %0d",p_bend);
 rot_ccw(1); if(p_bend!==-6'sd12) $fatal(1,"BEND must clamp at -12, got %0d",p_bend);
 press();
 $display("  ok BEND: +12/-12 clamps, previous timbre preserved");

 // VIB：0..3
 rot_cw(1); chk_item(2'd2); press();
 rot_cw(3);  if(p_vib!==2'd3) $fatal(1,"VIB up: want 3 got %0d",p_vib);
 rot_cw(1);  if(p_vib!==2'd3) $fatal(1,"VIB must clamp at 3");
 rot_ccw(3); if(p_vib!==2'd0) $fatal(1,"VIB down: want 0 got %0d",p_vib);
 rot_ccw(1); if(p_vib!==2'd0) $fatal(1,"VIB must clamp at 0");
 press();
 $display("  ok VIB: 0..3 with clamps");

 // DELAY：顺时针开、逆时针关
 rot_cw(1); chk_item(2'd3); press();
 rot_cw(1);  if(p_delay!==1'b1) $fatal(1,"DELAY clockwise must turn ON");
 rot_cw(1);  if(p_delay!==1'b1) $fatal(1,"DELAY must stay ON when rotated further");
 rot_ccw(1); if(p_delay!==1'b0) $fatal(1,"DELAY counter-clockwise must turn OFF");
 rot_ccw(1); if(p_delay!==1'b0) $fatal(1,"DELAY must stay OFF");
 press();
 $display("  ok DELAY: clockwise on / counter-clockwise off, no toggle-on-rotate");

 // 同拍按压 + 旋转：按压优先
 rot_cw(1); chk_item(3'd0);              // 延时 -> 音色（尾项回到首项）
 force dut.enc_step=1'b1;
 force dut.enc_sw_press=1'b1;
 @(negedge clk);
 release dut.enc_step;
 release dut.enc_sw_press;
 repeat(20) @(negedge clk);
 if(p_mode!==1'b1) $fatal(1,"simultaneous press+rotate: press must win");
 if(p_item!==2'd0) $fatal(1,"simultaneous press+rotate must not change the item");
 if(p_timbre!==2'd0) $fatal(1,"simultaneous press+rotate must not change the value");
 $display("  ok press wins over same-cycle rotation (item and value untouched)");
 press();                                 // 回浏览

 // 演奏指引/自动演奏已改为蓝牙命令控制，本 tb 不再覆盖，见 auto_play_tb / stop_restart_tb。

 // 测试模式：菜单暂停、参数保留、退出回浏览
 rot_cw(1); chk_item(3'd1);               // 停在 BEND
 force dut.k1_stable=1'b0;                // 进测试模式
 repeat(200) @(negedge clk);
 if(p_test!==1'b1) $fatal(1,"failed to enter test mode");
 if(p_mode!==1'b0) $fatal(1,"test mode must return the menu to BROWSE");
 // 测试模式期间旋转 + 按压都不许动参数
 rot_cw(3);
 press();
 if(p_item!==3'd1)   $fatal(1,"test mode must freeze the menu item");
 if(p_timbre!==2'd0) $fatal(1,"test mode must not change timbre");
 if(p_bend!==-6'sd12) $fatal(1,"test mode must not change bend");
 if(p_vib!==2'd0)    $fatal(1,"test mode must not change vibrato");
 if(p_delay!==1'b0)  $fatal(1,"test mode must not change delay");
 // 退出同样用 force：真实 key1 释放要过 6ms 去抖，该路径由 review_mode_tb 覆盖。
 force dut.k1_stable=1'b1;
 repeat(200) @(negedge clk);
 if(p_test!==1'b0) $fatal(1,"failed to leave test mode");
 if(p_mode!==1'b0) $fatal(1,"after test mode the menu must stay in BROWSE");
 if(p_bend!==-6'sd12 || p_timbre!==2'd0) $fatal(1,"params must survive test mode");
 $display("  ok test mode freezes the menu and preserves params, returns to BROWSE");

 $display("PASS review_knob: browse/edit FSM, 4-item wrap, clamps, one event per detent/press, press priority, test-mode freeze");
 $finish;
end
initial begin #120000000;$fatal(1,"knob timeout");end
endmodule
