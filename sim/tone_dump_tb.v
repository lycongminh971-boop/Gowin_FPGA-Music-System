`timescale 1ns/1ps
// tone_dump_tb.v —— 四种音色（单声部 C4）逐采样导出，供离线频谱/响度分析。
// 只做数据导出：out_flute/saw/clar/piano.csv，每行 n,dout,env，不含波形判据（仅保留超时保护）。
// env 列为白盒包络探针 g_env[0].env_k；saw 与 clar 只记前 12000 点，flute/piano 记到 30000 点。
module tone_dump_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;
 reg [9:0] div=0;
 always @(posedge clk) div<=div+1'b1;
 wire tick=(div==10'd0);
 wire signed [15:0] a0,a1,a2,a3;
 wire v0,v1,v2,v3,c0,c1,c2,c3;
 wire [0:0] act0,act1,act2,act3;
 wire [15:0] e0,e1,e2,e3;
 poly_engine #(.NB(1),.NP(32),.INSTRUMENT_PRESETS(1)) u0(
  .clk(clk),.rst(rst),.tick(tick),.pitch(7'h00),.gate(1'b1),.retrigger(1'b0),
  .bend(6'sd0),.vibrato(2'd0),.active(act0),.sample_valid(v0),.clip(c0),
  .env_hold(1'b0),.dout(a0),.timbre(2'd0));
 poly_engine #(.NB(1),.NP(32),.INSTRUMENT_PRESETS(1)) u1(
  .clk(clk),.rst(rst),.tick(tick),.pitch(7'h00),.gate(1'b1),.retrigger(1'b0),
  .bend(6'sd0),.vibrato(2'd0),.active(act1),.sample_valid(v1),.clip(c1),
  .env_hold(1'b0),.dout(a1),.timbre(2'd1));
 poly_engine #(.NB(1),.NP(32),.INSTRUMENT_PRESETS(1)) u2(
  .clk(clk),.rst(rst),.tick(tick),.pitch(7'h00),.gate(1'b1),.retrigger(1'b0),
  .bend(6'sd0),.vibrato(2'd0),.active(act2),.sample_valid(v2),.clip(c2),
  .env_hold(1'b0),.dout(a2),.timbre(2'd2));
 poly_engine #(.NB(1),.NP(32),.INSTRUMENT_PRESETS(1)) u3(
  .clk(clk),.rst(rst),.tick(tick),.pitch(7'h00),.gate(1'b1),.retrigger(1'b0),
  .bend(6'sd0),.vibrato(2'd0),.active(act3),.sample_valid(v3),.clip(c3),
  .env_hold(1'b0),.dout(a3),.timbre(2'd3));
 assign e0=u0.g_env[0].env_k; assign e1=u1.g_env[0].env_k;
 assign e2=u2.g_env[0].env_k; assign e3=u3.g_env[0].env_k;
 integer f0,f1,f2,f3,n;
 initial begin
  f0=$fopen("out_flute.csv","w"); f1=$fopen("out_saw.csv","w");
  f2=$fopen("out_clar.csv","w");  f3=$fopen("out_piano.csv","w");
  $fwrite(f0,"n,dout,env\n"); $fwrite(f1,"n,dout,env\n");
  $fwrite(f2,"n,dout,env\n"); $fwrite(f3,"n,dout,env\n");
  n=0;
  repeat(50) @(negedge clk); rst=0;
  while(n<30000) begin
   @(negedge clk);
   if(v0) begin $fwrite(f0,"%0d,%0d,%0d\n",n,a0,e0); n=n+1; end
   if(v1 && n<12000) $fwrite(f1,"%0d,%0d,%0d\n",n,a1,e1);
   if(v2 && n<12000) $fwrite(f2,"%0d,%0d,%0d\n",n,a2,e2);
   if(v3) $fwrite(f3,"%0d,%0d,%0d\n",n,a3,e3);
  end
  $fclose(f0); $fclose(f1); $fclose(f2); $fclose(f3);
  $display("DUMP tone_dump: %0d samples",n);
  $finish;
 end
 initial begin #1600000000; $fatal(1,"tone_dump timeout"); end
endmodule
