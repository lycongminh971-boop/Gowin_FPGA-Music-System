`timescale 1ns/1ps
// auto_play_tb —— 验证自动演奏的节拍与音符时序
// 覆盖：beat_gen 半拍/整拍位置；auto_player 的音符、休止、断音、推进、stop、曲终清键
// 判据：第 3 音为 key5(F4)；stop 立即清键；跑完整首后 done 拉起且按键归零
module auto_play_tb;
reg clk=0; always #10 clk=~clk;
reg rst=1;
integer errors=0,k;

task fail(input [255:0] msg);
 begin $display("FAIL: %0s",msg); errors=errors+1; end
endtask

wire t16g,thalfg;   // 直接量 beat_gen 输出的半拍/整拍脉冲
beat_gen #(.CLK_HZ(50_000)) u_beat(.clk(clk),.rst(rst),.tempo_idx(3'd3),
 .t16_tick(t16g),.t16_half(thalfg));

// song_ram 与 auto_player 的挂接
reg  we=0;
reg  [10:0] waddr=0;
reg  [7:0]  wdata=0;
wire [10:0] raddr;
wire [7:0]  rdata;
song_ram u_song(.clk(clk),.we(we),.waddr(waddr),.wdata(wdata),.raddr(raddr),.rdata(rdata));

reg  start=0,stop=0;
reg  [1:0] song_id=0;
reg  [8:0] cnt_in=0;
reg  t16=0,thalf=0;
wire [23:0] akeys;
wire busy,done;
wire [8:0] idx,total;
auto_player u_auto(.clk(clk),.rst(rst),.start(start),.song_id(song_id),.cnt_in(cnt_in),
 .stop(stop),.t16_tick(t16),.t16_half(thalf),.raddr(raddr),.rdata(rdata),
 .auto_keys(akeys),.busy(busy),.idx(idx),.total(total),.done(done));

task tick1; begin t16=1; @(posedge clk); t16=0; @(posedge clk); end endtask
task half1; begin thalf=1; @(posedge clk); thalf=0; @(posedge clk); end endtask

initial begin
 repeat(8) @(negedge clk);
 rst=0;
 k=0; @(negedge clk);
 while(!thalfg && k<40000) begin @(negedge clk); k=k+1; end
 $display("INFO B1 t16_half at %0d clk (expect ~3125)",k);
 if(k<3115 || k>3135) fail("B1 t16_half position");
 k=0;
 while(!t16g && k<40000) begin @(negedge clk); k=k+1; end
 $display("INFO B1 t16_tick +%0d clk after half (expect ~3125)",k);
 if(k<3110 || k>3135) fail("B1 t16_tick after half");

 we=1;
 waddr=11'd512;wdata=8'd0;  @(posedge clk);
 waddr=11'd513;wdata=8'd0;  @(posedge clk);
 waddr=11'd514;wdata=8'd0;  @(posedge clk);
 waddr=11'd515;wdata=8'd2;  @(posedge clk);
 waddr=11'd516;wdata=8'd8;  @(posedge clk);   // key3 对应 bit3
 waddr=11'd517;wdata=8'd0;  @(posedge clk);
 waddr=11'd518;wdata=8'd0;  @(posedge clk);
 waddr=11'd519;wdata=8'd2;  @(posedge clk);
 we=0;@(posedge clk);

 song_id=2'd0;cnt_in=9'd62;
 start=1;@(posedge clk);start=0;
 repeat(8) @(posedge clk);
 if(!busy)               fail("A1 busy should assert");
 if(akeys!==24'h000010)  fail("A1 first note should be key4 (E4)");
 $display("INFO A1 first note key4 sounding, akeys=%06h",akeys);

 // A2：dur=4，走 3 格仍发声
 tick1;tick1;tick1;
 repeat(2) @(posedge clk);
 if(akeys!==24'h000010) fail("A2 must still sound after 3 of 4 ticks");

 // A3：半格点断音
 half1;
 repeat(2) @(posedge clk);
 if(akeys!==24'h000000) fail("A3 t16_half must release the key");
 $display("INFO A3 staccato gap OK at half of last 1/16");

 tick1;
 repeat(8) @(posedge clk);
 if(idx!==9'd1)         fail("A4 idx should advance to 1");
 if(akeys!==24'h000010) fail("A4 second note also key4");

 tick1;tick1;tick1;half1;tick1;
 repeat(8) @(posedge clk);
 if(akeys!==24'h000020) fail("A5 third note should be key5 (F4)");
 $display("INFO A5 third note key5 ok, idx=%0d",idx);

 // A8：stop 立即清键
 stop=1;@(posedge clk);stop=0;@(posedge clk);
 if(akeys!==24'h000000) fail("A8 stop must clear auto_keys");
 if(busy)               fail("A8 stop must clear busy");
 $display("INFO A8 stop clears keys immediately");

 song_id=2'd1;cnt_in=9'd2;
 start=1;@(posedge clk);start=0;
 repeat(8) @(posedge clk);
 if(akeys!==24'h000000) fail("A6 rest must not sound");
 if(idx!==9'd0)         fail("A6 rest should hold idx at 0");
 tick1;
 repeat(2) @(posedge clk);
 if(idx!==9'd0)         fail("A6 rest dur=2 must not finish after 1 tick");
 tick1;
 repeat(8) @(posedge clk);
 if(akeys!==24'h000008) fail("A6 note after rest should be key3");
 $display("INFO A6 rest timed, next note key3 ok");

 // A7：跑完整首，曲终必须清键
 stop=1;@(posedge clk);stop=0;@(posedge clk);
 song_id=2'd0;cnt_in=9'd62;
 start=1;@(posedge clk);start=0;
 repeat(8) @(posedge clk);
 k=0;
 while(busy && k<3000) begin tick1; half1; k=k+1; end
 repeat(4) @(posedge clk);
 if(busy)               fail("A7 must finish within 3000 ticks");
 if(!done)              fail("A7 done must assert at end of song");
 if(akeys!==24'h000000) fail("A7 keys must be cleared at song end");
 $display("INFO A7 whole song finished in %0d ticks, keys cleared",k);

 if(errors!=0) begin $display("FAILED %0d checks",errors); $fatal(1,"auto_play_tb failed"); end
 $display("PASS auto_play: B1 beat half-point, A1..A8 note/rest/staccato/advance/stop/end");
 $finish;
end
initial begin #20000000;$fatal(1,"auto_play timeout");end
endmodule
