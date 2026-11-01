`timescale 1ns/1ps
// review_instrument_tb.v —— 音色对比：同音高下长笛与单簧管的 PCM 与起音包络。
// 覆盖：timbre=0/2 两套预设逐采样比较输出差异与非零比例。
// 判据：两者输出不同的采样数不少于 50；长笛 env_k 须小于单簧管且非零（起音更慢）。
// 注意：env_k 取自 g_env[0] 包络，属白盒探针。
module review_instrument_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1;
reg [9:0] div=0;
always @(posedge clk) div<=div+1'b1;
wire tick=(div==0);
wire signed [15:0] flute_audio,clar_audio;
wire fv,cv,fc,cc;
wire [15:0] fe,ce;
poly_engine #(.NB(1),.NP(32),.INSTRUMENT_PRESETS(1)) flute(
 .clk(clk),.rst(rst),.tick(tick),.pitch(7'h00),.gate(1'b1),.retrigger(1'b0),
 .bend(6'sd0),.vibrato(2'd0),.env_hold(1'b0),.timbre(2'd0),
 .dout(flute_audio),.sample_valid(fv),.clip(fc));
poly_engine #(.NB(1),.NP(32),.INSTRUMENT_PRESETS(1)) clarinet(
 .clk(clk),.rst(rst),.tick(tick),.pitch(7'h00),.gate(1'b1),.retrigger(1'b0),
 .bend(6'sd0),.vibrato(2'd0),.env_hold(1'b0),.timbre(2'd2),
 .dout(clar_audio),.sample_valid(cv),.clip(cc));
GSR GSR(.GSRI(1'b1));
assign fe=flute.g_env[0].env_k;
assign ce=clarinet.g_env[0].env_k;
integer different=0,nonzero_f=0,nonzero_c=0;
always @(negedge clk) if(!rst && fv && cv) begin
 if(flute_audio!=clar_audio) different=different+1;
 if(flute_audio!=0) nonzero_f=nonzero_f+1;
 if(clar_audio!=0) nonzero_c=nonzero_c+1;
 if(fc || cc || ^{flute_audio,clar_audio}===1'bx) $fatal(1,"instrument invalid/clipped output");
end
initial begin
 repeat(10) @(negedge clk);rst=0;
 repeat(100000) @(negedge clk);
 if(fe>=ce || fe==0) $fatal(1,"flute must have slower audible attack");
 if(different<50 || nonzero_f<50 || nonzero_c<50) $fatal(1,"presets must produce different audible PCM");
 $display("PASS review_instrument: different nonzero audio, distinct attack, no clipping");$finish;
end
initial begin #10000000;$fatal(1,"instrument timeout");end
endmodule
