// recorder_rest_tb —— 验证录音机把静音记成休止、连按不插休止
// 覆盖：C4 两拍 -> 静音三拍 -> D4 两拍应记三事件；两音紧邻只记两事件
// 判据：事件数与 keys/dur 落在容差内，rec_stop 后 rec_ready 拉起
module recorder_rest_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;

 reg  [23:0] keys=0;
 reg         rec_start=0, rec_stop=0, t16=0;
 wire        we;
 wire [10:0] waddr;
 wire [7:0]  wdata;
 wire        rec_busy, rec_ready, rec_full;
 wire [11:0] rec_bytes;

 recorder #(.AW(11),.DEPTH(2048)) u_dut(
  .clk(clk),.rst(rst),.keys(keys),
  .rec_start(rec_start),.rec_stop(rec_stop),.t16_tick(t16),
  .we(we),.waddr(waddr),.wdata(wdata),
  .rec_busy(rec_busy),.rec_ready(rec_ready),.rec_full(rec_full),
  .rec_bytes(rec_bytes));

 reg [7:0] mem [0:2047];
 always @(posedge clk) if(we) mem[waddr] <= wdata;

 task tick1; begin t16=1; @(posedge clk); t16=0; repeat(8) @(posedge clk); end endtask
 task tickn(input integer n); integer i; begin for(i=0;i<n;i=i+1) tick1; end endtask

 integer errors=0;
 integer nev,i;

 function [23:0] keys_at(input integer e); begin keys_at = {mem[e*4+2],mem[e*4+1],mem[e*4+0]}; end endfunction
 function [7:0]  dur_at(input integer e);  begin dur_at  = mem[e*4+3]; end endfunction

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(5) @(posedge clk);

  // 开始录音
  rec_start=1; @(posedge clk); rec_start=0; @(posedge clk);
  if(!rec_busy) begin $display("FAIL rec_busy should be 1"); errors=errors+1; end

  keys=24'd1; tickn(2);
  $display("INFO after C4 hold: bytes=%0d", rec_bytes);

  keys=24'd0; tickn(3);
  $display("INFO after 3-tick silence: bytes=%0d", rec_bytes);

  keys=24'd4; tickn(2);
  keys=24'd0;
  rec_stop=1; @(posedge clk); rec_stop=0;
  repeat(20) @(posedge clk);

  $display("INFO final: bytes=%0d ready=%b busy=%b", rec_bytes, rec_ready, rec_busy);
  if(!rec_ready) begin $display("FAIL rec_ready should be 1"); errors=errors+1; end

  nev = rec_bytes/4;
  $display("INFO event count = %0d (expect 3)", nev);
  for(i=0;i<nev;i=i+1) begin
   $display("  ev%0d: keys=%06h dur=%0d", i, keys_at(i), dur_at(i));
  end

  if(nev != 3) begin
   $display("FAIL expect 3 events (note, rest, note), got %0d", nev);
   errors=errors+1;
  end else begin
   // ev0：C4(key0)，时长约 2
   if(keys_at(0) !== 24'h000001) begin $display("FAIL ev0 keys=%06h want 000001",keys_at(0)); errors=errors+1; end
   if(dur_at(0) < 1 || dur_at(0) > 3) begin $display("FAIL ev0 dur=%0d want 1..3",dur_at(0)); errors=errors+1; end
   if(keys_at(1) !== 24'h000000) begin $display("FAIL ev1 should be REST, keys=%06h",keys_at(1)); errors=errors+1; end
   if(dur_at(1) < 2 || dur_at(1) > 4) begin $display("FAIL ev1 rest dur=%0d want 2..4",dur_at(1)); errors=errors+1; end
   // ev2：D4(key2)，时长约 2
   if(keys_at(2) !== 24'h000004) begin $display("FAIL ev2 keys=%06h want 000004",keys_at(2)); errors=errors+1; end
   if(dur_at(2) < 1 || dur_at(2) > 3) begin $display("FAIL ev2 dur=%0d want 1..3",dur_at(2)); errors=errors+1; end
  end

  repeat(10) @(posedge clk);
  rec_start=1; @(posedge clk); rec_start=0; @(posedge clk);
  repeat(2) @(posedge clk);

  keys=24'd1; tickn(2);          // C4 两拍
  keys=24'd0; repeat(3) @(posedge clk);   // 松手(不足一个 tick => 不产生休止)，再按下
  keys=24'd4; tickn(2);          // D4 两拍
  keys=24'd0;
  rec_stop=1; @(posedge clk); rec_stop=0;
  repeat(20) @(posedge clk);

  nev = rec_bytes/4;
  $display("INFO case2 event count = %0d (expect 2, no rest inserted)", nev);
  for(i=0;i<nev;i=i+1) begin
   $display("  ev%0d: keys=%06h dur=%0d", i, keys_at(i), dur_at(i));
  end
  if(nev != 2) begin
   $display("FAIL back-to-back notes should give 2 events, got %0d", nev);
   errors=errors+1;
  end

  if(errors==0) $display("PASS recorder_rest: silence recorded as rest events, back-to-back has none");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #2000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
