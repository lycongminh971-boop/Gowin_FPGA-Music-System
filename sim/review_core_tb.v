`timescale 1ns/1ps
// review_core_tb —— 4 声部 × 32 加法分量的整机回归，并导出 FFT 取样数据。
// 覆盖：24 键满按下 4 声部分配、松键尾音未落时重按、变调不重触发、扫描帧预算、门控静音。
// 判据：每帧扫描不超过 700 拍、音频无 X、4 声部 × 32 分量归一化不削顶。
// FFT 取样只开 voice0，其余声部 gate=0，结果写入 review_fft.csv。
module review_core_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1,test_mode=0;
reg [23:0] keys=0;
reg [3:0] test_gate=4'b1111;   // 测试模式下逐声部门控：FFT 阶段只开 voice0（单音 32 分量）
wire [27:0] pitch;
wire [3:0] gate,trig,active;
wire tick,bck,ws,din;
wire signed [15:0] audio;
wire valid,clip;
reg signed [5:0] bend=0;
wire [27:0] effective_pitch;
genvar k;
generate for(k=0;k<4;k=k+1) begin:t
 localparam [6:0] P=7'h00;                       // 4 声部统一 C4
 assign effective_pitch[7*k+:7]=test_mode?P:pitch[7*k+:7];
end endgenerate
wire [23:0] sounding;
voice_alloc #(.NK(24),.NV(4)) alloc(.clk(clk),.rst(rst),.key(keys),.active(active),
 .v_pitch(pitch),.v_gate(gate),.retrigger(trig),.sounding(sounding));
poly_engine eng(.clk(clk),.rst(rst),.tick(tick),.pitch(effective_pitch),
 .gate(test_mode?test_gate:gate),.retrigger(trig),.bend(bend),.vibrato(2'd0),
 .active(active),.env_hold(test_mode),.timbre({4{2'd1}}),.dout(audio),.sample_valid(valid),.clip(clip));
audio_tx tx(clk,rst,audio,tick,bck,ws,din);
GSR GSR(.GSRI(1'b1));
integer n,count,f;
integer samples=0,clocks_since_tick=0;
always @(posedge clk) if(!rst) begin
 if(tick) clocks_since_tick<=0;else clocks_since_tick<=clocks_since_tick+1;
 if(valid) begin
  // 每分量 5 拍，4*32=128 分量共 641 拍，留 700 拍余量。
  if(clocks_since_tick>700) $fatal(1,"scan deadline violated");
  if(^audio===1'bx) $fatal(1,"unknown audio");
  if(clip) $fatal(1,"4 voice x 32 harmonic normalization clipped");
 end
end
task check_count;
 input integer expected;
 begin
  count=0;for(n=0;n<4;n=n+1) if(active[n]) count=count+1;
  if(count!=expected) $fatal(1,"active=%0d expected=%0d",count,expected);
 end
endtask
initial begin
 repeat(10) @(negedge clk);rst=0;keys=24'hffffff;
 repeat(100) @(negedge clk);check_count(4);   // 24 键同时按，4 声部满载
 repeat(50000) @(negedge clk);
 keys[7:0]=0;repeat(50) @(negedge clk);
 keys[7:0]=255;repeat(100) @(negedge clk);check_count(4);  // 松键尾音未归零时重按
 bend=12;repeat(100) @(negedge clk);
 if(eng.g_key[0].oct!=1) $fatal(1,"live transpose missing");
 if(trig!=0) $fatal(1,"transpose retriggered ADSR");
 bend=-12;repeat(100) @(negedge clk);
 if(eng.g_key[0].oct!=7) $fatal(1,"negative transpose broken");
bend=0;test_mode=1;
repeat(3000) @(negedge clk);
// FFT 只对一个声部取样：4 声部相位不同步，第 n 次谐波会随相位差起伏。
// 单音 32 分量指一个音符内叠加 32 个分量，故只开 voice0，其余 gate=0。
test_gate=4'b0001;
repeat(2000) @(negedge clk);
// FFT 取 2048 点：@48.828kHz 分辨率 23.84Hz，C4 落在第 11 bin，谐波间隔 11 bin；
// 点数再多，32 位 ModelSim ASE 上一轮仿真跑不完。
f=$fopen("review_fft.csv","w");
repeat(2048) begin @(posedge valid);#1;$fdisplay(f,"%0d",audio);end
$fclose(f);
// 4 声部齐奏的归一化：全部门控，跑满若干帧确认不削顶（由上面的 clip 断言把关）。
test_gate=4'b1111;
repeat(2000) @(negedge clk);
// env_hold 必须按门控掩码生效，不能把所有静音声部一起打开。
 // force 门控归零后，dout 要跨一个 tick（sample_env 更新）加 641 拍扫描才归零，等满 2 帧（2048 拍）。
 force eng.gate=4'd0;
 repeat(2048) @(negedge clk);
 if(audio!==0) $fatal(1,"test mode ignored zero gate");
 release eng.gate;
 $display("PASS review_core: 4 voices x 32 harmonics, release overlap, transpose, frame budget, mute");
 $finish;
end
initial begin #250000000;$fatal(1,"core timeout");end
endmodule
