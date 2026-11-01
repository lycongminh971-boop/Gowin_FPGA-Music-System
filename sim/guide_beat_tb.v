`timescale 1ns/1ps
// guide_beat_tb —— 验证节拍生成与演奏指引的周期和命中判定。
// 覆盖 1/16 拍周期、命中与无自动前进、urgent 提示、休止符计时。
// 白盒检查命中后的熄灭窗口、长按不重复计数、窗口内按键计入下一格。
module guide_beat_tb;
reg clk=0; always #10 clk=~clk;
reg rst=1;
integer errors=0;
integer k;

task fail(input [255:0] msg);
 begin $display("FAIL: %0s",msg); errors=errors+1; end
endtask

// 1) beat_gen 周期检查
wire t16g,thalfg;
beat_gen #(.CLK_HZ(50_000)) u_beat(.clk(clk),.rst(rst),.tempo_idx(3'd3),
 .t16_tick(t16g),.t16_half(thalfg));

// 2) song_ram 与 guide_player
reg  we=0;
reg  [10:0] waddr=0;
reg  [7:0]  wdata=0;
wire [10:0] raddr;
wire [7:0]  rdata;
song_ram u_song(.clk(clk),.we(we),.waddr(waddr),.wdata(wdata),.raddr(raddr),.rdata(rdata));

reg  start=0,stop=0;
reg  [1:0] song_id=0;
reg  [8:0] cnt_in=0;
reg  [23:0] keys=0;
reg  t16=0;
wire busy,valid,urgent,done;
wire [23:0] tkeys;
wire [8:0] idx,total,hit,miss;
// 节奏模式：0 等待按键，1 到时限强制前进。
reg g_strict=0;
guide_player u_dut(.clk(clk),.rst(rst),.start(start),.song_id(song_id),.cnt_in(cnt_in),
 .stop(stop),.t16_tick(t16),.raddr(raddr),.rdata(rdata),.keys(keys),
 .busy(busy),.target_keys(tkeys),.target_valid(valid),.urgent(urgent),
 .idx(idx),.total(total),.done(done),.hit_cnt(hit),.miss_cnt(miss),.strict(g_strict));

task tick1; begin t16=1; @(posedge clk); t16=0; @(posedge clk); end endtask
task press(input [4:0] kk); begin keys=24'd1<<kk; @(posedge clk); @(posedge clk); keys=24'd0; @(posedge clk); end endtask

initial begin
 // T1 beat_gen 周期
 repeat(8) @(negedge clk);
 rst=0;
 k=0;
 @(negedge clk);
 while(!t16g && k<40000) begin @(negedge clk); k=k+1; end
 $display("INFO T1 t16 period = %0d clk (expect 6250 @CLK_HZ=50000,120BPM)",k);
 if(k<6245 || k>6255) fail("T1 beat_gen 1/16 period");

 we=1;
 waddr=11'd512;wdata=8'd0;  @(posedge clk);
 waddr=11'd513;wdata=8'd0;  @(posedge clk);
 waddr=11'd514;wdata=8'd0;  @(posedge clk);
 waddr=11'd515;wdata=8'd2;  @(posedge clk);
 waddr=11'd516;wdata=8'd8;  @(posedge clk);
 waddr=11'd517;wdata=8'd0;  @(posedge clk);
 waddr=11'd518;wdata=8'd0;  @(posedge clk);
 waddr=11'd519;wdata=8'd2;  @(posedge clk);
 we=0;@(posedge clk);

 song_id=2'd0;cnt_in=9'd62;
 start=1;@(posedge clk);start=0;
 repeat(8) @(posedge clk);
 if(!valid)          fail("first note not valid");
 if(tkeys!==24'h000010) fail("first note should be key4 (E4)");

 tick1;tick1;tick1;tick1;
 repeat(4) @(posedge clk);
 if(idx!==9'd0)  fail("T3 idx must NOT advance without a key press");
 if(miss!==9'd0) fail("T3 miss_cnt must stay 0 (no auto-advance)");
 if(hit!==9'd0)  fail("T3 hit_cnt should still be 0");
 if(!valid)      fail("T3 target must stay valid");
 if(tkeys!==24'h000010) fail("T3 target must still be key4");
 if(!urgent)     fail("T3 urgent must be high after the deadline");
 $display("INFO T3 no auto-advance OK, idx=%0d miss=%0d urgent=%0d",idx,miss,urgent);

 repeat(4) @(posedge clk);
 press(5'd4);
 repeat(4) @(posedge clk);
 if(hit!==9'd1)  fail("T2 hit_cnt should be 1 after first press");
 if(idx!==9'd1)  fail("T2 idx should advance to 1 only after a press");
 if(miss!==9'd0) fail("T2 miss_cnt must stay 0");
  tick1;   // 命中后先熄灭一个 1/16 拍，再打一拍才前进。
 repeat(8) @(posedge clk);
 if(!valid)       fail("second note not valid");
 if(tkeys!==24'h000010) fail("second note should be key4");
 press(5'd4);
 repeat(4) @(posedge clk);
 if(hit!==9'd2)  fail("T2 hit_cnt should be 2 after second press");
  tick1;   // 命中后先熄灭一个 1/16 拍，再打一拍才前进。
 repeat(8) @(posedge clk);
 if(tkeys!==24'h000020) fail("third note should be key5 (F4)");
 $display("INFO T2 hit OK, idx=%0d hit=%0d miss=%0d",idx,hit,miss);

 tick1;tick1;
 repeat(2) @(posedge clk);
 if(!urgent) fail("T4 urgent should be high at half of dur=4");
 $display("INFO T4 urgent OK at half of dur4");
 press(5'd5);
 repeat(8) @(posedge clk);

 stop=1;@(posedge clk);stop=0;@(posedge clk);
 song_id=2'd1;cnt_in=9'd2;
 start=1;@(posedge clk);start=0;
 repeat(8) @(posedge clk);
 if(valid) fail("T5 rest must not assert target_valid");
 if(idx!==9'd0) fail("T5 rest should hold idx=0 while counting");
 tick1;
 repeat(2) @(posedge clk);
 if(idx!==9'd0) fail("T5 rest dur=2 must not finish after 1 tick");
 tick1;
 repeat(8) @(posedge clk);
 if(!valid)      fail("T5 after rest should show next note");
 if(tkeys!==24'h000008) fail("T5 note after rest should be key3");
 $display("INFO T5 rest timed OK");

 // T6：连续两个相同键事件要松开再按，熄灭期间不重复计数。
 begin : t6
  stop=1;@(posedge clk);stop=0;@(posedge clk);

  // 槽位 3：两个事件都是 key4（LO = 1<<4 = 0x10），dur=8
  we=1;
  waddr=11'd1536;wdata=8'h10; @(posedge clk);
  waddr=11'd1537;wdata=8'h00; @(posedge clk);
  waddr=11'd1538;wdata=8'h00; @(posedge clk);
  waddr=11'd1539;wdata=8'd8;   @(posedge clk);
  waddr=11'd1540;wdata=8'h10; @(posedge clk);
  waddr=11'd1541;wdata=8'h00; @(posedge clk);
  waddr=11'd1542;wdata=8'h00; @(posedge clk);
  waddr=11'd1543;wdata=8'd8;   @(posedge clk);
  we=0;@(posedge clk);

  song_id=2'd3;cnt_in=9'd2;
  start=1;@(posedge clk);start=0;
  repeat(8) @(posedge clk);
  if(!valid) fail("T6 first event should be valid");
  if(tkeys!==24'h000010) fail("T6 first event should be key4");

  // 按住不放，命中第一格
  keys=24'd1<<4;
  repeat(4) @(posedge clk);
  if(hit!==9'd1) fail("T6 first event should be hit by holding key4");
  if(idx!==9'd1) fail("T6 idx should be 1 after first hit");

  // 命中后目标灯先熄灭（G_BLNK），不能常亮。
  if(valid) begin
    $display("T6 FAIL: after hit the target should be OFF (G_BLNK), but valid=1");
    fail("T6 lights must turn OFF right after a hit, then light up again");
  end
  $display("INFO T6 blank OK: target_valid=0 right after hit (light OFF)");

  // 整格熄灭期间不应再累计命中
  repeat(32) @(posedge clk);
  if(idx!==9'd1) begin
    $display("T6 idx=%0d (expect 1 while blanked)",idx);
    fail("T6 must not advance while blanked");
  end
  if(hit!==9'd1) fail("T6 must not count twice while blanked");

  // tick1 越过熄灭间隔 -> 点亮第二格
  tick1;
  repeat(6) @(posedge clk);
  if(!valid) fail("T6 second event should light up after the blank");
  if(tkeys!==24'h000010) fail("T6 second event should be key4 again");

  // 仍按住不放时，第二格不应命中，必须先松开。
  repeat(16) @(posedge clk);
  if(hit!==9'd1) begin
    $display("T6 hit=%0d (expect 1: holding must NOT count the repeated event)",hit);
    fail("T6 holding a key must NOT auto-count the repeated identical event");
  end

  // 松开 -> 再按，第二格才命中
  keys=24'd0;
  repeat(4) @(posedge clk);
  keys=24'd1<<4;
  repeat(4) @(posedge clk);
  if(hit!==9'd2) begin
    $display("T6 idx=%0d hit=%0d (expect hit=2 after release+repress)",idx,hit);
    fail("T6 release+repress must count the repeated event");
  end
  if(idx!==9'd2) fail("T6 should advance to idx=2 after repress");

  // 再 tick1 越过熄灭间隔 -> 曲终 done
  tick1;
  keys=24'd0;
  repeat(6) @(posedge clk);
  if(!done) fail("T6 should be done after both events");
  $display("INFO T6 press-twice OK: idx=%0d hit=%0d done=%0d",idx,hit,done);
 end

 // T7：熄灭窗口内按下的键要计入下一格命中。
 begin : t7
  stop=1;@(posedge clk);stop=0;@(posedge clk);

  // 槽位 3 已经是两个 key4 事件（T6 写的），直接复用
  song_id=2'd3;cnt_in=9'd2;
  start=1;@(posedge clk);start=0;
  repeat(8) @(posedge clk);
  if(!valid) fail("T7 first event should be valid");

  press(5'd4);
  repeat(4) @(posedge clk);
  if(hit!==9'd1) fail("T7 first press should hit ev0");
  if(valid)      fail("T7 should be in blank window (light OFF)");

  // 熄灭间隔里再按一次（此时还没到下一个 tick）-> 必须被记下来
  press(5'd4);
  repeat(4) @(posedge clk);
  if(idx!==9'd1) fail("T7 must stay blanked before the tick");

  tick1;
  repeat(8) @(posedge clk);
  if(hit!==9'd2) begin
    $display("T7 hit=%0d (expect 2: press during blank must count)",hit);
    fail("T7 press during the blank interval must count the repeated event");
  end
  if(idx!==9'd2) fail("T7 should advance to idx=2");
  $display("INFO T7 blank-press OK: hit=%0d idx=%0d (no third press needed)",hit,idx);
 end

 if(errors!=0) begin $display("FAILED %0d checks",errors); $fatal(1,"guide_beat_tb failed"); end
 $display("PASS guide_beat: T1 beat period, T2 hit, T3 no-auto-advance, T4 urgent, T5 rest timing, T6 hold-through");
 $finish;
end
initial begin #20000000;$fatal(1,"guide_beat timeout");end

endmodule
