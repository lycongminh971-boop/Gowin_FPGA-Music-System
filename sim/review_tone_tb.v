`timescale 1ns/1ps
// review_tone_tb —— 四种音色（SINE/SAW/SQUARE/TRI）加法合成权重回归。
// 覆盖：切音色不改相位/不重触发 ADSR、32 分量权重律与静音条件、峰值比例、四声部混音不削顶。
// 判据：逐项读 w_tab 与 mute_comp 对照定义值；峰值比按数值积分给 ±10% 容差；clip 必须为 0。
// 说明：用 F5 缩短单周期帧数，32 次谐波仍低于 fs/2，不会被反混叠滤掉。
module review_tone_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1;
reg [3:0] gate=4'd0;
reg [1:0] timbre=2'd1;
wire tick,bck,ws,din;
wire [3:0] active;
wire signed [15:0] audio;
wire valid,clip;
localparam [27:0] PITCH_F5=28'h15;   // oct=1,semi=5 → F5 698.46Hz
// 不用 C4：C4 一个周期要 187 帧，四种音色各测一周期就是 700+ 帧；
// F5 只要 70 帧，且 32 次谐波 22350Hz 仍低于 fs/2=24.4kHz。
localparam integer FRAMES_1PERIOD=72;  // 一个 F5 周期 = 70 帧，留 2 帧余量
poly_engine #(.NB(4),.NP(32),.MIX_SHIFT(3)) eng(
 .clk(clk),.rst(rst),.tick(tick),.pitch(PITCH_F5),.gate(gate),
 .retrigger(4'd0),.bend(6'sd0),.vibrato(2'd0),.active(active),
 .env_hold(1'b1),.timbre({4{timbre}}),.dout(audio),.sample_valid(valid),.clip(clip));
audio_tx tx(clk,rst,audio,tick,bck,ws,din);
GSR GSR(.GSRI(1'b1));

// 层级探针（直接比较层次化寄存器会触发 vlog 内部错误）
wire [31:0] p_ph0  = eng.g_osc[0].phase_r;
wire [3:0]  p_trig = eng.v_trig;
integer peak,clips,m;
integer ph_a,ph_b;
integer peak_sine,peak_saw,peak_sqr,peak_tri;
always @(posedge clk) if(!rst && valid) begin
 m=audio;                       // signed [15:0] → integer，自动符号扩展
 if(m<0) m=-m;
 if(clip) clips=clips+1;
 if(m>peak) peak=m;
end

// 期望权重（Q15，1.0 = 32767）
function integer w_lin_exp;      // 1/n
 input integer n;
 begin w_lin_exp = (32768 + n/2) / n; end
endfunction
function integer w_sq_exp;       // 1/n²
 input integer n;
 begin w_sq_exp = (32768 + (n*n)/2) / (n*n); end
endfunction
function integer w_tri_even_exp; // 0.1/n²
 input integer n;
 begin w_tri_even_exp = (32768 + 5*(n*n)) / (10*(n*n)); end
endfunction

integer k,n,err;
reg [4:0] pci;
reg signed [15:0] wt;
reg mc;
initial begin
 repeat(10) @(negedge clk);rst=0;
 repeat(20) @(negedge clk);

 // 第 0 层：切音色不动相位、不重触发 ADSR、不改变按键
 // 判据：相位继续前进、无 ADSR 重触发、门控声部不变。
 gate=4'd1; timbre=2'd1;
 repeat(2048) @(negedge clk);
 ph_a=p_ph0;
 timbre=2'd3;                      // SAW -> TRI
 repeat(2048) @(negedge clk);
 ph_b=p_ph0;
 if(ph_b<=ph_a)      $fatal(1,"timbre switch reset/rewound the phase accumulator (%0d -> %0d)",ph_a,ph_b);
 if(p_trig!==4'd0)   $fatal(1,"timbre switch retriggered the envelope");
 if(active!==4'd1)   $fatal(1,"timbre switch changed the gated voice");
 $display("  ok timbre switch: phase keeps running, no ADSR retrigger, gate unchanged");
 timbre=2'd1;
 repeat(2048) @(negedge clk);

 // 第 1 层：逐分量核对权重律
 force eng.sample_timbre={4{2'd1}};      // SAW
 #5;
 for(k=0;k<32;k=k+1) begin
  pci=k; force eng.pc=pci; #5;
  n=k+1; wt=$signed(eng.w_tab); mc=eng.mute_comp;
  err=(wt<0?(-wt):wt)-w_lin_exp(n);
  if(err>2 || err<-2) $fatal(1,"SAW n=%0d weight=%0d expect=%0d",n,wt,w_lin_exp(n));
  if(mc!==1'b0)       $fatal(1,"SAW n=%0d must not be muted",n);
 end
 $display("  ok SAW: 32 components, |w|=1/n, none muted");

 force eng.sample_timbre={4{2'd0}};      // SINE
 #5;
 for(k=0;k<32;k=k+1) begin
  pci=k; force eng.pc=pci; #5;
  mc=eng.mute_comp;
  if(k==0) begin
   if(mc!==1'b0) $fatal(1,"SINE fundamental must not be muted");
   wt=$signed(eng.w_tab);
   if(wt<32700)  $fatal(1,"SINE fundamental weight=%0d",wt);
  end else if(mc!==1'b1) $fatal(1,"SINE n=%0d must be muted",k+1);
 end
 $display("  ok SINE: fundamental only, all pc>0 muted");

 force eng.sample_timbre={4{2'd2}};      // SQUARE
 #5;
 for(k=0;k<32;k=k+1) begin
  pci=k; force eng.pc=pci; #5;
  n=k+1; wt=$signed(eng.w_tab); mc=eng.mute_comp;
  if(n%2==0) begin
   if(mc!==1'b1) $fatal(1,"SQUARE even n=%0d must be muted",n);
  end else begin
   if(mc!==1'b0) $fatal(1,"SQUARE odd n=%0d must not be muted",n);
   err=(wt<0?(-wt):wt)-w_lin_exp(n);
   if(err>2 || err<-2) $fatal(1,"SQUARE n=%0d weight=%0d expect=%0d",n,wt,w_lin_exp(n));
   if(wt<0) $fatal(1,"SQUARE n=%0d weight must be positive",n);
  end
 end
 $display("  ok SQUARE: odd harmonics only, |w|=1/n, even muted");

 force eng.sample_timbre={4{2'd3}};      // TRI
 #5;
 for(k=0;k<32;k=k+1) begin
  pci=k; force eng.pc=pci; #5;
  n=k+1; wt=$signed(eng.w_tab); mc=eng.mute_comp;
  if(n%2==1) begin
   // 奇次：1/n²
   err=(wt<0?(-wt):wt)-w_sq_exp(n);
   if(err>2 || err<-2) $fatal(1,"TRI n=%0d |w|=%0d expect=%0d",n,(wt<0?(-wt):wt),w_sq_exp(n));
  end else begin
   // 偶次：0.1/n²（轻微不对称，用来加厚音色）
   err=(wt<0?(-wt):wt)-w_tri_even_exp(n);
   if(err>2 || err<-2) $fatal(1,"TRI even n=%0d |w|=%0d expect=%0d",n,(wt<0?(-wt):wt),w_tri_even_exp(n));
  end
  if(mc!==1'b0) $fatal(1,"TRI n=%0d must not be muted",n);
  // 符号：n % 4 == 3 取负，其余取正
  if((n%4==3) && wt>0) $fatal(1,"TRI n=%0d sign must be -, got %0d",n,wt);
  if((n%4!=3) && wt<0) $fatal(1,"TRI n=%0d sign must be +, got %0d",n,wt);
 end
 $display("  ok TRI: 32 components, odd 1/n^2, even 0.1/n^2, sign negative at n%%4==3");
 release eng.pc;
 release eng.sample_timbre;

 // 第 2 层：峰值比例兜底
 // 每种音色跑满一个 F5 周期，取 |sample| 最大值。
 // 切音色后第一帧仍出旧音色（sample_timbre 在 tick 才锁存），
 // 所以每种音色先空跑 4 帧，避免旧样本混进新峰值。
 gate=4'd1; clips=0;
 timbre=2'd0; repeat(4*1024) @(negedge clk);
 peak=0; repeat(FRAMES_1PERIOD*1024) @(negedge clk); peak_sine=peak;
 timbre=2'd1; repeat(4*1024) @(negedge clk);
 peak=0; repeat(FRAMES_1PERIOD*1024) @(negedge clk); peak_saw=peak;
 timbre=2'd2; repeat(4*1024) @(negedge clk);
 peak=0; repeat(FRAMES_1PERIOD*1024) @(negedge clk); peak_sqr=peak;
 timbre=2'd3; repeat(4*1024) @(negedge clk);
 peak=0; repeat(FRAMES_1PERIOD*1024) @(negedge clk); peak_tri=peak;
 $display("  peaks (single voice, full env): SINE=%0d SAW=%0d SQUARE=%0d TRI=%0d",
          peak_sine,peak_saw,peak_sqr,peak_tri);
 if(clips!=0) $fatal(1,"single-voice timbre sweep clipped %0d times",clips);
 if(peak_sine<=0||peak_saw<=0||peak_sqr<=0||peak_tri<=0) $fatal(1,"a timbre produced silence");
 // 理论峰值比（对部分和数值积分求得）：SAW/SINE=1.804、SQUARE/SINE=0.926、
 // TRI/SINE=1.218、TRI/SQUARE=1.315，容差 ±10%。
 // 区分度：SQUARE 漏偶次静音会退化成 SAW；TRI 符号全同号会让 TRI/SINE 掉到 0.92。
 if(peak_saw*100 < peak_sine*162 || peak_saw*100 > peak_sine*199)
  $fatal(1,"SAW/SINE peak ratio out of range: %0d/%0d",peak_saw,peak_sine);
 if(peak_sqr*100 < peak_sine*83  || peak_sqr*100 > peak_sine*102)
  $fatal(1,"SQUARE/SINE peak ratio out of range (even harmonics leaked?): %0d/%0d",peak_sqr,peak_sine);
 if(peak_tri*100 < peak_sine*110 || peak_tri*100 > peak_sine*134)
  $fatal(1,"TRI/SINE peak ratio out of range (alternating sign wrong?): %0d/%0d",peak_tri,peak_sine);
 if(peak_tri*100 < peak_sqr*118 || peak_tri*100 > peak_sqr*145)
  $fatal(1,"TRI/SQUARE peak ratio out of range (sign must alternate): %0d/%0d",peak_tri,peak_sqr);
 $display("  ok peak ratios consistent with SINE=1 component, SAW=sum 1/n, SQUARE/TRI=odd only");

 // 第 3 层：四声部不削顶
 gate=4'd15; clips=0; peak=0;
 for(k=0;k<4;k=k+1) begin
  timbre=k;
  repeat(32*1024) @(negedge clk);
 end
 if(clips!=0) $fatal(1,"4-voice mix clipped %0d times (MIX_SHIFT=3 too small?)",clips);
 $display("  ok 4-voice mix: 0 clips across 4 timbres, peak=%0d",peak);

 $display("PASS review_tone: weight law exact for SINE/SAW/SQUARE/TRI, TRI signs alternate, peaks sane, 4-voice no clip");
 $finish;
end
initial begin #40000000;$fatal(1,"tone timeout");end
endmodule
