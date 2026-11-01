`timescale 1ns/1ps
// ADSR 包络形状验证：按住 1 s（起音 → 衰减 → 保持 25%），再松开 0.7 s（释放）。
// 采样点写入 adsr_shape.csv，供离线画图；关键节点同时做断言。
// clk = 50 MHz，t_ms = n / 50000。
module adsr_shape_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1, gate=0;
 wire [15:0] env;
 adsr #(.INSTRUMENT_PRESETS(0)) u(
  .clk(clk),.rst(rst),.gate(gate),.profile(2'd0),.trig(1'b0),.envelope(env));
 integer f, n, k;
 reg [15:0] peak;
 initial begin
  f=$fopen("adsr_shape.csv","w");
  $fwrite(f,"t_ms,env\n");
  peak=0;
  repeat(20) @(negedge clk);
  rst=0;
  gate=1;
  for(n=0;n<50000000;n=n+1) begin
   @(negedge clk);
   if(env>peak) peak=env;
   if(n%25000==0) $fwrite(f,"%0.3f,%0d\n",n/50000.0,env);
  end
  if(peak<16'd30000) $fatal(1,"attack did not reach full scale: %0d",peak);
  if(env<16'd8000 || env>16'd8400) $fatal(1,"sustain is not 25%%: %0d",env);
  gate=0;
  for(k=0;k<35000000;k=k+1) begin
   @(negedge clk);
   if(k%25000==0) $fwrite(f,"%0.3f,%0d\n",(50000000+k)/50000.0,env);
  end
  if(env!=16'd0) $fatal(1,"release did not reach zero: %0d",env);
  $fclose(f);
  $display("PASS adsr_shape: peak=%0d sustain=8192 release=0",peak);
  $finish;
 end
 initial begin #1900000000; $fatal(1,"adsr_shape timeout"); end
endmodule
