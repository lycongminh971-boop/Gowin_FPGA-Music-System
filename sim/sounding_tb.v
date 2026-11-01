// sounding_tb —— 验证 sounding 只跟实际发声的声部走
// 覆盖：按 1/4/5/8 个键与全松，NV=4 只有 4 路声部
// 判据：sounding 置位数不超过 4，全松后归零
module sounding_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;
 reg  [23:0] keys=0;
 wire [7*4-1:0] vp;      // NV=4 时位宽为 4*7
 wire [3:0] vg, rt;
 wire [23:0] sounding;

 voice_alloc #(.NK(24),.NV(4)) u(
  .clk(clk),.rst(rst),.key(keys),
  .active(4'd0),
  .v_pitch(vp),.v_gate(vg),.retrigger(rt),
  .sounding(sounding));

 integer errors=0;
 function integer pop;
  input [23:0] v; integer i;
  begin pop=0; for(i=0;i<24;i=i+1) if(v[i]) pop=pop+1; end
 endfunction

 task settle; integer t; begin for(t=0;t<40;t=t+1) @(posedge clk); end endtask

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(5) @(posedge clk);

  // 按 1 个键：sounding 只应有 1 位
  keys=24'h000001;   // key0
  settle;
  if(pop(sounding)!=1) begin $display("FAIL 1 key: sounding=%06h pop=%0d",sounding,pop(sounding)); errors=errors+1; end
  if(!sounding[0]) begin $display("FAIL key0 should sound, sounding=%06h",sounding); errors=errors+1; end
  $display("INFO 1 key -> sounding=%06h pop=%0d",sounding,pop(sounding));

  // 按 4 个键：正好用满 4 路
  keys=24'h00000F;   // key0..3
  settle;
  if(pop(sounding)!=4) begin $display("FAIL 4 keys: sounding=%06h pop=%0d want 4",sounding,pop(sounding)); errors=errors+1; end
  $display("INFO 4 keys -> sounding=%06h pop=%0d",sounding,pop(sounding));

  // 关键用例：按 5 个键，只有 4 路声部
  keys=24'h00001F;   // key0..4 五个键
  settle;
  $display("INFO 5 keys -> sounding=%06h pop=%0d (want 4)",sounding,pop(sounding));
  if(pop(sounding)!=4) begin
   $display("FAIL 5 keys should sound only 4, got %0d",pop(sounding));
   errors=errors+1;
  end

  // 按 8 个键，仍只能 4 个
  keys=24'h0000FF;
  settle;
  $display("INFO 8 keys -> sounding=%06h pop=%0d (want 4)",sounding,pop(sounding));
  if(pop(sounding)!=4) begin
   $display("FAIL 8 keys should sound only 4, got %0d",pop(sounding));
   errors=errors+1;
  end

  // 全松：sounding 回 0
  keys=24'h000000;
  settle;
  $display("INFO released -> sounding=%06h pop=%0d (want 0)",sounding,pop(sounding));
  if(pop(sounding)!=0) begin
   $display("FAIL release should clear sounding, got %06h",sounding);
   errors=errors+1;
  end

  if(errors==0) $display("PASS sounding: LED follows real voices (max 4), not raw key presses");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #1000000; $fatal(1,"timeout"); end
endmodule
