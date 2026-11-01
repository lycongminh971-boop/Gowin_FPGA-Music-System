module poly_engine #(
 parameter INSTRUMENT_PRESETS = 0, 
 parameter integer NB        = 4,    
 parameter integer NP        = 32,   
 parameter integer MIX_SHIFT = 3    
)(
 input  wire clk, input wire rst, input wire tick,
 input  wire [7*NB-1:0]    pitch,    // 每声部 7 位 {oct[2:0], semi[3:0]}
 input  wire [NB-1:0]      gate,
 input wire [NB-1:0] retrigger,
 input wire signed [5:0] bend, 
 input wire [1:0] vibrato, 
 output wire [NB-1:0] active,
 output reg sample_valid,
 output reg clip,
 input  wire               env_hold, // 测试模式：包络恒满幅，绕过 ADSR
 output reg  signed [15:0] dout,
 input  wire [2*NB-1:0]    timbre    // 每声部 2 位：0=SINE 1=SAW 2=SQUARE 3=TRI
);
localparam integer NV = NB*NP;              // 相位振荡器总数：默认128（4声部×32谐波）
localparam integer IW = (NV<=1)?1:$clog2(NV);   // 分量扫描索引位宽
localparam integer KW = (NB<=1)?1:$clog2(NB);   // 键索引位宽
localparam integer PW = (NP<=1)?1:$clog2(NP);   // 键内分量序号位宽
localparam integer SW = 17+$clog2(NV);          // 混音累加位宽（默认128分量 → 24位）
localparam [1:0] TONE_SINE=2'd0,TONE_SAW=2'd1,TONE_SQUARE=2'd2,TONE_TRI=2'd3;

// 输入每系统时钟采样；包络和音色在tick锁定
reg [7*NB-1:0] pitch_q;
reg [NB-1:0]   gate_q, gate_prev;
wire [NB-1:0]  v_trig = (gate_q & ~gate_prev) | retrigger;   // 上升沿或分配器显式重触发重新起音
always @(posedge clk) begin
 if(rst) begin pitch_q<={NB{7'h7f}}; gate_q<=0; gate_prev<=0; end
 else begin pitch_q<=pitch; gate_q<=gate; gate_prev<=gate_q; end
end

function [31:0] oct_shift;
 input [31:0] b; input [2:0] o;
 begin
  case(o)
   3'd0: oct_shift = b;
   3'd1: oct_shift = b << 1;
   3'd2: oct_shift = b << 2;
   3'd3: oct_shift = b << 3;
   3'd7: oct_shift = b >> 1; // 修改批注：向下实时变调
   default: oct_shift = 32'd0;
  endcase
 end
endfunction

wire [32*NB-1:0] key_bs;
reg [15:0] lfo;
always @(posedge clk) begin
 if(rst) lfo<=0;
 else if(tick) lfo<=lfo+16'd7;
end
wire signed [9:0] triangle=lfo[15] ?
 (10'sd127-$signed({2'b00,lfo[14:7]})) :
 ($signed({2'b00,lfo[14:7]})-10'sd128);
reg signed [11:0] triangle_depth;
always @(posedge clk) begin
 if(rst) triangle_depth<=0;
 else case(vibrato)
  0:triangle_depth<=0;
  1:triangle_depth<=triangle;
  2:triangle_depth<=$signed(triangle)*12'sd2;
  3:triangle_depth<=$signed(triangle)*12'sd3;
 endcase
end
genvar k;
generate for(k=0;k<NB;k=k+1) begin:g_key
 wire [6:0] original_pitch=pitch_q[7*k +:7];
 reg signed [8:0] note_number;
 reg [3:0] semi;
 reg signed [8:0] note_pipe;
 reg [2:0] oct;
 always @* begin
  note_number=$signed({1'b0,original_pitch[6:4]})*12+
              $signed({1'b0,original_pitch[3:0]})+$signed(bend);
 end
 always @(posedge clk) begin
  if(rst) note_pipe<=0;else note_pipe<=note_number;
 end
 reg signed [8:0] bounded_note;
 always @* begin
  bounded_note=note_pipe;
  if(bounded_note < -12) bounded_note=-12;
  if(bounded_note > 47) bounded_note=47;
  if(bounded_note<0) begin oct=7;semi=bounded_note+12;end
  else if(bounded_note<12) begin oct=0;semi=bounded_note[3:0];end
  else if(bounded_note<24) begin oct=1;semi=bounded_note-12;end
  else if(bounded_note<36) begin oct=2;semi=bounded_note-24;end
  else begin oct=3;semi=bounded_note-36;end
  if(original_pitch[3:0]>11) semi=15;
 end
 reg [3:0] semi_pipe;
 reg [2:0] oct_pipe,oct_delayed;
 always @(posedge clk) begin
  if(rst) begin semi_pipe<=15;oct_pipe<=0;oct_delayed<=0;end
  else begin semi_pipe<=semi;oct_pipe<=oct;oct_delayed<=oct_pipe;end
 end
 reg [31:0] base,base_pipe;
 always @(posedge clk) begin
  if(rst) base_pipe<=0;else base_pipe<=base;
 end
 always @* begin
        case (semi_pipe)
            4'd0 : base = 32'd23012828;     // C4   261.6256 Hz
            4'd1 : base = 32'd24381242;     // C#4  277.1826 Hz
            4'd2 : base = 32'd25831026;     // D4   293.6648 Hz
            4'd3 : base = 32'd27367019;     // D#4  311.1270 Hz
            4'd4 : base = 32'd28994347;     // E4   329.6276 Hz
            4'd5 : base = 32'd30718440;     // F4   349.2282 Hz
            4'd6 : base = 32'd32545054;     // F#4  369.9944 Hz
            4'd7 : base = 32'd34480283;     // G4   391.9954 Hz
            4'd8 : base = 32'd36530588;     // G#4  415.3047 Hz
            4'd9 : base = 32'd38702809;     // A4   440.0000 Hz
            4'd10: base = 32'd41004198;     // A#4  466.1638 Hz
            4'd11: base = 32'd43442435;     // B4   493.8833 Hz
            default: base = 32'd0;          // 4'hF 及未用编码 = 静音
        endcase
    end
 // 修改批注：音高译码、八度、乘法、求和分别注册，控制延后不足0.2us。
 reg [31:0] nominal,nominal_delayed,frequency;
 reg signed [44:0] modulation;
 always @(posedge clk) begin
  if(rst) begin nominal<=0;nominal_delayed<=0;modulation<=0;frequency<=0;end
  else begin
   nominal<=oct_shift(base_pipe,oct_delayed);
   nominal_delayed<=nominal;
   modulation<=$signed({1'b0,nominal})*triangle_depth;
   frequency<=$signed({1'b0,nominal_delayed})+(modulation>>>15);
  end
 end
 assign key_bs[32*k +:32]=frequency;
end endgenerate
wire [32*NV-1:0] phase_flat;
wire [NV-1:0]    alias_flat;   // 每分量：频率达到 fs/2 及以上时为 1，该分量必须静音
genvar v;
generate for(v=0;v<NV;v=v+1) begin:g_osc
 localparam integer KK = v / NP;   // 归属键（elaboration 常量，纯布线）
 localparam integer CC = v % NP;   // 分量序号 0..NP-1，倍率 = CC+1
 wire [31:0] bs = key_bs[32*KK +: 32];
 wire [37:0] stp_full = {6'd0, bs} * (CC+1);
 wire [31:0] stp = stp_full[31:0];
 assign alias_flat[v] = (stp_full >= 38'h8000_0000);
 reg [31:0] phase_r;
 always @(posedge clk) begin
  if(rst) phase_r <= 32'd0;
  else if(tick) phase_r <= phase_r + stp;   // 所有分量在同一 tick 推进，故不能共享 step
 end
 assign phase_flat[32*v +: 32] = phase_r;
end endgenerate
wire [16*NB-1:0] env_flat;
generate for(k=0;k<NB;k=k+1) begin:g_env
 wire [15:0] env_k;
 adsr #(.INSTRUMENT_PRESETS(INSTRUMENT_PRESETS)) u_adsr(.clk(clk),.rst(rst),.gate(gate_q[k]),.trig(v_trig[k]),.profile(timbre[2*k +: 2]),.envelope(env_k));
 assign env_flat[16*k +: 16] = env_k;
 assign active[k]=gate_q[k] | (env_k!=0) | retrigger[k];
end endgenerate

reg [16*NB-1:0] sample_env;
reg [2*NB-1:0]  sample_timbre;
generate for(k=0;k<NB;k=k+1) begin:g_senv
 always @(posedge clk) begin
  if(rst) sample_env[16*k +: 16] <= 16'd0;
  else if(tick) sample_env[16*k +: 16] <= (key_bs[32*k +:32]==0) ? 16'd0 : (env_hold ? (gate_q[k]?16'd32767:16'd0) : env_flat[16*k +: 16]);
 end
end endgenerate
always @(posedge clk) begin
 if(rst) sample_timbre <= 0;
 else if(tick) sample_timbre <= timbre;   // 帧首锁存：一帧内 32 个分量看到的音色必然一致
end
reg [IW-1:0] vi;
reg [KW-1:0] ki;
reg [PW-1:0] pc;

wire [31:0] sel_phase = phase_flat[32*vi +: 32];
wire [15:0] env_sel   = sample_env[16*ki +: 16];
wire [1:0]  tim_sel   = sample_timbre[2*ki +: 2];

wire [15:0] rom_dout;
Gowin_ROM u_rom(.dout(rom_dout),.clk(clk),.oce(1'b1),.ce(1'b1),
 .reset(rst),.ad(sel_phase[31:22]));
// 修改批注：两种音色均由ROM正弦谐波合成，移除未使用的旧方波支路。

// ---- 单套乘法器（默认时分192次复用）----
reg signed [15:0] wave_sample;
reg signed [15:0] env_s;
wire signed [31:0] product = wave_sample * env_s;
reg signed [31:0] product_q; // 修改批注：乘法与移位累加拆拍，避免MUX→乘法→累加长路径。
reg [15:0] w_lin;
always @* begin
 case(pc)
  5'd0 : w_lin = 16'd32767;  // 1/1（用 32767 而不是 32768：权重改成有符号 16 位，32768 会溢出）
  5'd1 : w_lin = 16'd16384;  // 1/2
  5'd2 : w_lin = 16'd10923;  // 1/3
  5'd3 : w_lin = 16'd8192;   // 1/4
  5'd4 : w_lin = 16'd6554;   // 1/5
  5'd5 : w_lin = 16'd5461;   // 1/6
  5'd6 : w_lin = 16'd4681;   // 1/7
  5'd7 : w_lin = 16'd4096;   // 1/8
  5'd8 : w_lin = 16'd3641;   // 1/9
  5'd9 : w_lin = 16'd3277;   // 1/10
  5'd10: w_lin = 16'd2979;   // 1/11
  5'd11: w_lin = 16'd2731;   // 1/12
  5'd12: w_lin = 16'd2521;   // 1/13
  5'd13: w_lin = 16'd2341;   // 1/14
  5'd14: w_lin = 16'd2185;   // 1/15
  5'd15: w_lin = 16'd2048;   // 1/16
  5'd16: w_lin = 16'd1928;   // 1/17
  5'd17: w_lin = 16'd1820;   // 1/18
  5'd18: w_lin = 16'd1725;   // 1/19
  5'd19: w_lin = 16'd1638;   // 1/20
  5'd20: w_lin = 16'd1560;   // 1/21
  5'd21: w_lin = 16'd1489;   // 1/22
  5'd22: w_lin = 16'd1425;   // 1/23
  5'd23: w_lin = 16'd1365;   // 1/24
  5'd24: w_lin = 16'd1311;   // 1/25
  5'd25: w_lin = 16'd1260;   // 1/26
  5'd26: w_lin = 16'd1214;   // 1/27
  5'd27: w_lin = 16'd1170;   // 1/28
  5'd28: w_lin = 16'd1130;   // 1/29
  5'd29: w_lin = 16'd1092;   // 1/30
  5'd30: w_lin = 16'd1057;   // 1/31
  default: w_lin = 16'd1024;// 1/32
 endcase
end
reg [15:0] w_tri_mag;
always @* begin
 case(pc)
  5'd0 : w_tri_mag = 16'd32767;  // n=1   1/1²
  5'd1 : w_tri_mag = 16'd819;    // n=2   偶次 0.1/4
  5'd2 : w_tri_mag = 16'd3641;   // n=3   1/9
  5'd3 : w_tri_mag = 16'd205;    // n=4
  5'd4 : w_tri_mag = 16'd1311;   // n=5   1/25
  5'd5 : w_tri_mag = 16'd91;     // n=6
  5'd6 : w_tri_mag = 16'd669;    // n=7   1/49
  5'd7 : w_tri_mag = 16'd51;     // n=8
  5'd8 : w_tri_mag = 16'd405;    // n=9   1/81
  5'd9 : w_tri_mag = 16'd33;     // n=10
  5'd10: w_tri_mag = 16'd271;    // n=11
  5'd11: w_tri_mag = 16'd23;     // n=12
  5'd12: w_tri_mag = 16'd194;    // n=13
  5'd13: w_tri_mag = 16'd17;     // n=14
  5'd14: w_tri_mag = 16'd146;    // n=15
  5'd15: w_tri_mag = 16'd13;     // n=16
  5'd16: w_tri_mag = 16'd113;    // n=17
  5'd17: w_tri_mag = 16'd10;     // n=18
  5'd18: w_tri_mag = 16'd91;     // n=19
  5'd19: w_tri_mag = 16'd8;      // n=20
  5'd20: w_tri_mag = 16'd74;     // n=21
  5'd21: w_tri_mag = 16'd7;      // n=22
  5'd22: w_tri_mag = 16'd62;     // n=23
  5'd23: w_tri_mag = 16'd6;      // n=24
  5'd24: w_tri_mag = 16'd52;     // n=25
  5'd25: w_tri_mag = 16'd5;      // n=26
  5'd26: w_tri_mag = 16'd45;     // n=27
  5'd27: w_tri_mag = 16'd4;      // n=28
  5'd28: w_tri_mag = 16'd39;     // n=29
  5'd29: w_tri_mag = 16'd4;      // n=30
  5'd30: w_tri_mag = 16'd34;     // n=31
  default: w_tri_mag = 16'd3;    // n=32
 endcase
end
reg signed [15:0] instrument_weight;
always @* begin
 instrument_weight=0;
 if(tim_sel==TONE_SINE) begin
  case(pc)                                        // ---- FLUTE ----
   5'd0 :instrument_weight=32767; 5'd1 :instrument_weight=3932;
   5'd2 :instrument_weight=1966;  5'd3 :instrument_weight=655;
   5'd4 :instrument_weight=524;   5'd5 :instrument_weight=437;
   5'd6 :instrument_weight=374;   5'd7 :instrument_weight=328;
   5'd8 :instrument_weight=291;   5'd9 :instrument_weight=262;
   5'd10:instrument_weight=238;   5'd11:instrument_weight=218;
   5'd12:instrument_weight=202;   5'd13:instrument_weight=187;
   5'd14:instrument_weight=175;   5'd15:instrument_weight=164;
   5'd16:instrument_weight=154;   5'd17:instrument_weight=146;
   5'd18:instrument_weight=138;   5'd19:instrument_weight=131;
   5'd20:instrument_weight=125;   5'd21:instrument_weight=119;
   5'd22:instrument_weight=114;   5'd23:instrument_weight=109;
   5'd24:instrument_weight=105;   5'd25:instrument_weight=101;
   5'd26:instrument_weight=97;    5'd27:instrument_weight=94;
   5'd28:instrument_weight=90;    5'd29:instrument_weight=87;
   5'd30:instrument_weight=85;    default:instrument_weight=82;
  endcase
 end else begin
  case(pc)                                        // ---- CLAR ----
   5'd0 :instrument_weight=32767; 5'd1 :instrument_weight=492;
   5'd2 :instrument_weight=18022; 5'd3 :instrument_weight=246;
   5'd4 :instrument_weight=8192;  5'd5 :instrument_weight=164;
   5'd6 :instrument_weight=3932;  5'd7 :instrument_weight=123;
   5'd8 :instrument_weight=2294;  5'd9 :instrument_weight=98;
   5'd10:instrument_weight=1311;  5'd11:instrument_weight=82;
   5'd12:instrument_weight=819;   5'd13:instrument_weight=70;
   5'd14:instrument_weight=492;   5'd15:instrument_weight=61;
   5'd16:instrument_weight=385;   5'd17:instrument_weight=55;
   5'd18:instrument_weight=309;   5'd19:instrument_weight=49;
   5'd20:instrument_weight=253;   5'd21:instrument_weight=45;
   5'd22:instrument_weight=211;   5'd23:instrument_weight=41;
   5'd24:instrument_weight=178;   5'd25:instrument_weight=38;
   5'd26:instrument_weight=153;   5'd27:instrument_weight=35;
   5'd28:instrument_weight=132;   5'd29:instrument_weight=33;
   5'd30:instrument_weight=116;   default:instrument_weight=31;
  endcase
 end
end
wire instrument_mode = INSTRUMENT_PRESETS && (tim_sel==TONE_SINE || tim_sel==TONE_SQUARE);
wire is_tri = (tim_sel==TONE_TRI);
wire signed [15:0] w_mag = is_tri ? $signed(w_tri_mag) : $signed(w_lin);
wire tri_neg = is_tri & ~pc[0] & pc[1];
wire signed [15:0] w_tab = instrument_mode ? instrument_weight : tri_neg ? (-w_mag) : w_mag;
wire mute_comp = instrument_mode ? 1'b0
               : (tim_sel==TONE_SINE) ? (pc!=5'd0)
               : (tim_sel==TONE_SQUARE && pc[0]);

wire signed [15:0] w_base = $signed(product_q[30:15]);
wire signed [31:0] w_prod = w_base * w_tab;
reg  signed [31:0] w_prod_q;
wire signed [15:0] scaled = w_prod_q[30:15];
reg  signed [SW-1:0] sum;
wire signed [SW-1:0] attenuated = sum >>> MIX_SHIFT;

reg [2:0] scan_state;
localparam IDLE=0,FETCH=1,CAPTURE=2,MULTIPLY=3,WEIGHT=4,ACCUMULATE=5,FINISH=6;
reg alias_q;
wire alias_sel = alias_flat[vi];
always @(posedge clk) begin
 if(rst) begin
  vi<=0;ki<=0;pc<=0;scan_state<=IDLE;sum<=0;dout<=0;wave_sample<=0;sample_valid<=0;clip<=0;env_s<=0;product_q<=0;w_prod_q<=0;alias_q<=0;
 end else if(tick) begin
  vi<=0;ki<=0;pc<=0;sum<=0;scan_state<=FETCH;sample_valid<=0;
 end else case(scan_state)
  FETCH:begin env_s<=env_sel;alias_q<=alias_sel;scan_state<=CAPTURE;end // 同时锁存包络与 alias，等待同步ROM。
  CAPTURE:begin
   if(mute_comp || alias_q)
    wave_sample<=0;
   else wave_sample<=$signed(rom_dout);
   scan_state<=MULTIPLY;
  end
  MULTIPLY:begin product_q<=product;scan_state<=WEIGHT;end
  WEIGHT:begin w_prod_q<=w_prod;scan_state<=ACCUMULATE;end
  ACCUMULATE:begin
   sum<=sum+{{(SW-16){scaled[15]}},scaled};
   if(vi==NV-1) scan_state<=FINISH;
   else begin
    vi<=vi+1'b1;
    // 每 NP 个分量换一个键：这样 ki 不需要除法器，只是一次回绕判断
    if(pc==NP-1) begin pc<=0; ki<=ki+1'b1; end
    else                pc<=pc+1'b1;
    scan_state<=FETCH;
   end
  end
  FINISH:begin
   sample_valid<=1;
   clip<=(attenuated>32767 || attenuated< -32768);
   if(attenuated>32767) dout<=16'sd32767;
   else if(attenuated< -32768) dout<=-16'sd32768;
   else dout<=attenuated[15:0];
   scan_state<=IDLE;
  end
  default:begin scan_state<=IDLE;sample_valid<=0;end
 endcase
end
// synthesis translate_off
initial if(NV<1 || 5*NV+2>=1024) $fatal(1,"NV exceeds audio frame budget");
initial if(NP<1 || NP>32)         $fatal(1,"poly_engine: NP must be 1..32 (weight table)");
// synthesis translate_on
endmodule
