`timescale 1ns/1ps
// vol_map 交互行为验证：跟随距离、无效读数保持、边界抖动、离开恢复、断线恢复。
// D_NEAR=100 mm，D_FAR=400 mm，窗口内 12.5%~100%，平滑时间常数约 1.31 ms。
module review_vol_tb;
 reg clk=0;
 always #10 clk=~clk;
 reg rst=1;
 reg [15:0] dist_mm=0;
 reg dist_vld=0,rs_ok=0;
 wire [15:0] vol_q;
 vol_map dut(.clk(clk),.rst(rst),.dist_mm(dist_mm),.dist_vld(dist_vld),.rs_ok(rs_ok),.vol_q(vol_q));
 localparam integer FRAME_NS = 40_000_000;   // 一帧测距 40 ms
 localparam integer SETTLE_NS = 8_000_000;   // 平滑收敛（约 6 个时间常数）
 localparam integer VMAX = 32768;
 // 平滑度监视：每 1024 clk 采一次，等价于每次平滑更新的步长
 integer prev,max_step,d;
 reg mon=0;
 reg [9:0] mon_div=0;
 always @(posedge clk) begin
  mon_div<=mon_div+1'b1;
  if(mon && mon_div==10'd0) begin
   d=vol_q-prev; if(d<0) d=-d;
   if(d>max_step) max_step=d;
   prev=vol_q;
  end
 end
 task frame;
  input [15:0] dmm;
  input ok;
  begin
   // 映射用寄存后的 lin_r，晚一帧生效；真实测距是连续流，这里每个距离连发两帧。
   @(negedge clk); dist_mm=dmm; rs_ok=ok; dist_vld=1;
   @(negedge clk); dist_vld=0;
   @(negedge clk); dist_vld=1;
   @(negedge clk); dist_vld=0;
  end
 endtask
 task wait_ns;
  input integer ns;
  begin repeat(ns/20) @(negedge clk); end
 endtask
 task check_vol;
  input [127:0] name;
  input integer expect;
  input integer tol;
  integer e;
  begin
   e=vol_q-expect; if(e<0) e=-e;
   if(e>tol) $fatal(1,"%0s: vol=%0d expect=%0d tol=%0d",name,vol_q,expect,tol);
   $display("  ok %0s vol=%0d",name,vol_q);
  end
 endtask
 integer i;
 initial begin
  repeat(5) @(negedge clk); rst=0;
  repeat(2) @(negedge clk);
  check_vol("reset_full",VMAX,0);
  // 1. 窗口内跟随：200 mm→18432，300 mm→8875，贴手→满音量
  frame(200,1); wait_ns(SETTLE_NS);
  check_vol("follow200mm",18432,200);
  frame(300,1); wait_ns(SETTLE_NS);
  check_vol("follow300mm",8875,200);
  frame(100,1); wait_ns(SETTLE_NS);
  check_vol("follow100mm",VMAX,200);
  frame(300,1); wait_ns(SETTLE_NS);
  check_vol("base300mm",8875,200);
  // 2. 短时无效读数（太近/弱信号）保持，不跟随
  for(i=0;i<3;i=i+1) begin
   frame(0,1);  wait_ns(FRAME_NS/4);
   frame(30,0); wait_ns(FRAME_NS/4);
  end
  check_vol("hold_invalid60",8875,300);
  frame(300,0); wait_ns(SETTLE_NS);
  check_vol("hold_weak",8875,300);
  // 3. 边界抖动：395/405 跨 D_FAR，音量不许跳回满
  prev=vol_q; max_step=0; mon=1;
  for(i=0;i<8;i=i+1) begin
   frame(395,1); wait_ns(FRAME_NS/8);
   frame(405,1); wait_ns(FRAME_NS/8);
  end
  mon=0;
  if(vol_q>6000) $fatal(1,"boundary jitter caused volume jump: vol=%0d",vol_q);
  $display("  ok boundary jitter stayed low vol=%0d",vol_q);
  // 4. 持续超远端 → 100 ms 后平滑恢复满音量
  frame(300,1); wait_ns(SETTLE_NS);
  check_vol("preleave300",8875,200);
  prev=vol_q; max_step=0; mon=1;
  frame(3000,1);
  wait_ns(60_000_000);
  check_vol("leave60_hold",8875,300);
  wait_ns(90_000_000);
  check_vol("leave150_full",VMAX,300);
  mon=0;
  if(max_step>600) $fatal(1,"volume ramp not smooth: max_step=%0d",max_step);
  $display("  ok restore ramp smooth max_step=%0d",max_step);
  // 5. 手回到窗口内继续跟随
  frame(300,1); wait_ns(SETTLE_NS);
  check_vol("resume_track",8875,200);
  // 6. 断线：100 ms 缺口保持，600 ms 后恢复
  wait_ns(100_000_000);
  check_vol("gap100_hold",8875,300);
  wait_ns(500_000_000);
  check_vol("gap600_full",VMAX,300);
  // 7. 8190 超量程且 rs_ok=0 同样判定为手已离开
  frame(300,1); wait_ns(SETTLE_NS);
  check_vol("base_b4_8190",8875,200);
  frame(8190,0);
  wait_ns(150_000_000);
  check_vol("r8190_as_left",VMAX,300);
  $display("PASS review_vol: follow, hold-invalid, jitter, leave-restore, link-loss, 8190, smooth");
  $finish;
 end
 initial begin #1500000000; $fatal(1,"vol timeout"); end
endmodule
