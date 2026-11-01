// star.v —— 顶层：24 键电子琴 + 4 声部合成 + 蓝牙曲谱 + RGB LCD
//
//   音频：poly_engine 每声部 32 谐波加法合成 → PT8211（LSBJ）
//   声部：voice_alloc NV=4
//   节拍：beat_gen 产生 1/16 拍脉冲 t16_tick，GUIDE / AUTO / 录音共用同一物理时基
//   曲谱：song_ram 4 槽 × 512 字节，每事件 4 字节 {KEYS_LO, KEYS_MID, KEYS_HI, DUR}
//   蓝牙：bt_link 解析 A5 帧，负责写曲谱、控播放、改参数、录音控制
//   录音：recorder 把按键序列化成曲谱格式（不回传音频）
module star #(parameter INSTRUMENT_PRESETS=1, 
parameter AUDIO_I2S=0, parameter LCD_BACKLIGHT_ENABLE=1,
 parameter LCD_TEST_PATTERN=0)(
 input wire clk,rst_n,key1,
 output wire hp_bck,hp_ws,hp_din,pa_en,
 input  wire bt_rxd,
 output wire bt_txd,
 inout wire mpr_scl,mpr_sda,mpr2_scl,mpr2_sda,vl53_scl,vl53_sda,
 input wire enc_a,enc_b,enc_sw,
 output wire uart_txd,tlc_clk,tlc_sin,tlc_lat,tlc_bla,
 output wire lcd_clk,lcd_hs,lcd_vs,lcd_de,lcd_bl,
 output wire [5:0] lcd_r,lcd_g,lcd_b
);
localparam NB=4,NP=32;
(* syn_preserve=1 *) reg [1:0] reset_sync=0,key1_sync=3;
reg [15:0] por_count=0;
always @(posedge clk) begin
 reset_sync<={reset_sync[0],rst_n};
 key1_sync<={key1_sync[0],key1};
 if(!reset_sync[1]) 
    por_count<=0;
 else if(por_count<49999) 
 por_count<=por_count+1'b1;
end
wire rst=(!reset_sync[1]) || (por_count<49999);
reg [18:0] k1_count;
reg k1_stable;
always @(posedge clk) begin
 if(rst) begin 
  k1_count<=0;
  k1_stable<=1;
  end
 else if(key1_sync[1]==k1_stable) 
 k1_count<=0;
 else if(k1_count==299999) begin 
  k1_stable<=key1_sync[1];
  k1_count<=0;
  end
 else 
 k1_count<=k1_count+1'b1;
end
wire test_mode=~k1_stable;
reg test_previous;
always @(posedge clk) begin
 if(rst) 
  test_previous<=0;
 else 
  test_previous<=test_mode;
end
wire audio_reset=rst | (test_previous!=test_mode);
wire [11:0] touch_key,touch_key2;
wire touch_ready,touch_fault,touch_ready2,touch_fault2;
mpr121 u_mpr(.clk(clk),
  .rst(rst),
  .scl(mpr_scl),
  .sda(mpr_sda),
  .key(touch_key),
  .ready(touch_ready),
  .fault(touch_fault),
  .frame_stb());
mpr121 #(.DEV_ADDR(7'h5a)) u_mpr2(.clk(clk),
  .rst(rst),
  .scl(mpr2_scl),
  .sda(mpr2_sda),
  .key(touch_key2),
  .ready(touch_ready2),
  .fault(touch_fault2),
  .frame_stb());
wire [23:0] key_all={touch_key2,touch_key};
wire enc_step,enc_dir,enc_sw_press;
ec11_decode #(.CLK_HZ(50000000),.FILT_US(200),.SW_MS(20),.DETENT_Q(2),.INV_DIR(0)) u_enc(
 .clk(clk),
 .rst(rst),
 .io_a(enc_a),
 .io_b(enc_b),
 .io_sw(enc_sw),
 .step(enc_step),
 .dir(enc_dir),
 .sw_level(),
 .sw_press(enc_sw_press));
reg [7:0] enc_pos;
localparam [1:0] IT_TONE=2'd0,IT_BEND=2'd1,IT_VIB=2'd2,IT_DELAY=2'd3;
localparam [2:0] IT_MAX=3'd3;
localparam [1:0] TONE_SINE=2'd0,TONE_SAW=2'd1,TONE_SQUARE=2'd2,TONE_TRI=2'd3;
reg select_mode;                 // 0=浏览 1=调整
reg [2:0] item;
reg [1:0] timbre_select;
reg [1:0] vibrato;
reg delay_on;
reg signed [5:0] bend;
reg [1:0] bt_song;
// 蓝牙/指引模块的状态线
wire [3:0] bt_ready;
wire [2:0] bt_state;
wire       bt_link_ok,bt_guide_start,bt_guide_stop;
wire [1:0] bt_cmd_song;
wire [8:0] bt_rx_done,bt_rx_total;
wire [35:0] bt_counts;
wire       bt_auto_start,bt_set_vld,bt_rec_start,bt_rec_stop;
wire [1:0] bt_auto_song;
wire [2:0] bt_set_param,bt_tempo_sel;
wire       bt_tempo_vld;
wire       bt_strict;        // 2026-10-29: GUIDE 严格节奏模式（SET param=5）
reg  [2:0] tempo_sel;
wire [7:0] bt_set_val;
wire [10:0] bt_rec_raddr,rec_waddr;
wire [7:0]  rec_rdata,rec_wdata;
wire        rec_busy,rec_ready,rec_full,rec_we;
wire [11:0] rec_bytes;
wire       g_busy,g_valid,g_done;
wire [23:0] g_targets;
wire [8:0] g_idx,g_total;
wire       a_busy,a_done;
wire [8:0] a_idx,a_total;
wire [23:0] auto_keys;
wire rot_step = enc_step & ~enc_sw_press;
wire g_start = bt_guide_start && !test_mode && !rec_busy;
// 自动演奏的启动源：同上，只剩手机 MODE=2
wire a_start = bt_auto_start && !test_mode && !g_start && !rec_busy;
wire g_stop  = bt_guide_stop | test_mode | a_start;
wire a_stop  = test_mode | g_start | bt_guide_stop;
wire [1:0] g_song = bt_guide_start ? bt_cmd_song : bt_song;
wire [1:0] a_song = bt_auto_start ? bt_auto_song : bt_song;
wire [8:0] g_cnt  = bt_counts[9*g_song +: 9];
wire       play_busy = g_busy | a_busy | g_done | a_done;
wire [8:0] disp_done  = play_busy ? ((a_busy|a_done) ? a_idx   : g_idx)   : bt_rx_done;
wire [8:0] disp_total = play_busy ? ((a_busy|a_done) ? a_total : g_total) : bt_rx_total;
always @(posedge clk) begin
 if(rst) begin
  enc_pos<=0;select_mode<=1'b0;item<=IT_TONE;
  timbre_select<=TONE_SAW;bend<=0;vibrato<=0;delay_on<=0;
  tempo_sel<=3'd3;
  bt_song<=2'd0;
 end else begin
  if(bt_guide_start) bt_song<=bt_cmd_song;
  if(bt_auto_start)  bt_song<=bt_auto_song;
  if(bt_tempo_vld) tempo_sel<=bt_tempo_sel;
  if(bt_set_vld && !test_mode) begin
   case(bt_set_param)
    3'd0: timbre_select <= bt_set_val[1:0];
    3'd1: bend           <= bt_set_val[5:0] - 6'd12;
    3'd2: vibrato        <= bt_set_val[1:0];
    3'd3: delay_on       <= bt_set_val[0];
    default: ;
   endcase
  end
  if(enc_step) enc_pos<=enc_dir?enc_pos+1'b1:enc_pos-1'b1;
  if(test_mode) begin
   select_mode<=1'b0;
  end else if(enc_sw_press) begin
   select_mode<=~select_mode;
  end else if(rot_step) begin
   if(!select_mode) begin
    if(enc_dir) item<=(item==IT_MAX)?3'd0:item+1'b1;
    else        item<=(item==3'd0)?IT_MAX:item-1'b1;
   end else begin
    case(item)
     IT_TONE: begin
      if(enc_dir && timbre_select<TONE_TRI)        timbre_select<=timbre_select+1'b1;
      else if(!enc_dir && timbre_select>TONE_SINE) timbre_select<=timbre_select-1'b1;
     end
     IT_BEND: begin
      if(enc_dir && bend<6'sd12)        bend<=bend+1'b1;
      else if(!enc_dir && bend>-6'sd12) bend<=bend-1'b1;
     end
     IT_VIB: begin
      if(enc_dir && vibrato<2'd3)       vibrato<=vibrato+1'b1;
      else if(!enc_dir && vibrato>2'd0) vibrato<=vibrato-1'b1;
     end
     IT_DELAY: delay_on<=enc_dir;
     default: ;
    endcase
   end
  end
 end
end
wire [7*NB-1:0] kb_pitch,pitch_all;
wire [NB-1:0] kb_gate,retrigger,active;
//   原因：测试模式的音高/门控已经被下面的 mux 完全接管，分配器在这里复位没有任何收益；
wire [23:0] key_eff = key_all | auto_keys;
wire [23:0] sounding;
voice_alloc #(.NK(24),.NV(NB)) u_alloc(.clk(clk),.rst(rst),
 .key(key_eff),.active(active),.v_pitch(kb_pitch),.v_gate(kb_gate),.retrigger(retrigger),
 .sounding(sounding));
genvar k;
generate for(k=0;k<NB;k=k+1) begin:g_pitch
 localparam [6:0] TEST_PITCH=7'h00;
 assign pitch_all[7*k+:7]=test_mode?TEST_PITCH:kb_pitch[7*k+:7];
end endgenerate
localparam [NB-1:0] TEST_GATE={{ (NB-1){1'b0} },1'b1};
wire tick,engine_valid,engine_clip;
wire signed [15:0] audio;
poly_engine #(.INSTRUMENT_PRESETS(INSTRUMENT_PRESETS),.NB(NB),.NP(NP),.MIX_SHIFT(3)) u_eng(
  .clk(clk),
  .rst(audio_reset),
  .tick(tick),
  .pitch(pitch_all),
  .gate(test_mode?TEST_GATE:kb_gate),
  .retrigger(retrigger),
  .bend(test_mode?6'sd0:bend),
  .vibrato(test_mode?2'd0:vibrato),
  .active(active),
  .env_hold(test_mode),
  .timbre(test_mode?{NB{TONE_SAW}}:{NB{timbre_select}}),
  .dout(audio),
  .sample_valid(engine_valid),
  .clip(engine_clip));
wire [15:0] dist_mm,vol_q;
wire dist_vld,rs_ok,vl_dev_found;
wire [3:0] rs_code;
vl53l0x u_tof(
  .clk(clk),
  .rst(rst),
  .dist_mm(dist_mm),
  .dist_vld(dist_vld),
  .rs_ok(rs_ok),
  .rs_code(rs_code),
  .dev_found(vl_dev_found),
  .scl(vl53_scl),
  .sda(vl53_sda));
vol_map u_vol(.clk(clk),
  .rst(rst),
  .dist_mm(dist_mm),
  .dist_vld(dist_vld),
  .rs_ok(rs_ok),
  .vol_q(vol_q));
wire signed [16:0] vol_s={1'b0,(test_mode?16'd32768:vol_q)};
wire signed [32:0] mv=audio*vol_s;
wire signed [15:0] audio_v=mv[30:15];
wire signed [15:0] audio_fx;
audio_delay u_fx(.clk(clk),
.rst(audio_reset),
.valid(engine_valid),
.enable(delay_on && !test_mode),
 .din(audio_v),
 .dout(audio_fx),
 .dout_valid());
audio_tx #(.I2S_MODE(AUDIO_I2S)) u_tx(.clk(clk),
.rst(rst),
.sample(audio_fx),
 .tick(tick),
 .bck(hp_bck),
 .ws(hp_ws),
 .din(hp_din));
assign pa_en=rst;
//     bt_rxd（AA19）← 模块 TXD
//     bt_txd（AB20）→ 模块 RXD
wire [7:0] bt_rx_byte,bt_tx_byte;
wire       bt_rx_vld,bt_tx_send,bt_tx_busy;
uart_rx u_bt_rx(
  .clk(clk),
  .rst(rst),
  .rx(bt_rxd),
  .data(bt_rx_byte),
  .valid(bt_rx_vld));
uart_tx u_bt_tx(
  .clk(clk),
  .rst(rst),
  .send(bt_tx_send),
  .data(bt_tx_byte),
  .tx(bt_txd),
  .busy(bt_tx_busy));
wire        song_we;
wire [10:0] song_waddr;
wire [7:0]  song_wdata;
bt_link u_bt(
  .clk(clk),
  .rst(rst),
  .rx_data(bt_rx_byte),
  .rx_valid(bt_rx_vld),
  .tx_data(bt_tx_byte),
  .tx_send(bt_tx_send),
  .tx_busy(bt_tx_busy),
  .song_we(song_we),
  .song_waddr(song_waddr),
  .song_wdata(song_wdata),
  .ready_mask(bt_ready),
  .link_ok(bt_link_ok),
  .rx_done(bt_rx_done),
  .rx_total(bt_rx_total),
 .state(bt_state),.guide_start(bt_guide_start),.guide_song(bt_cmd_song),
 .guide_stop(bt_guide_stop),.song_counts(bt_counts),
 // 2026-10-26 新增端口
 .auto_start(bt_auto_start),.auto_song(bt_auto_song),
 .set_vld(bt_set_vld),.set_param(bt_set_param),.set_val(bt_set_val),
 .tempo_sel(bt_tempo_sel),.tempo_vld(bt_tempo_vld),.strict_rhythm(bt_strict),.cur_tempo(tempo_sel),
 .cur_tone(timbre_select),.cur_bend(bend),.cur_vib(vibrato),.cur_delay(delay_on),
 .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),
 .rec_raddr(bt_rec_raddr),.rec_rdata(rec_rdata),
 .rec_busy(rec_busy),.rec_ready(rec_ready),.rec_full(rec_full),.rec_bytes(rec_bytes));
wire [10:0] g_raddr,a_raddr;
wire [7:0]  rd_rdata;
wire        t16_tick,t16_half;
wire        g_urgent;
wire [8:0]  g_hit,g_miss;
beat_gen #(.CLK_HZ(50000000)) u_beat(
 .clk(clk),
 .rst(rst | g_start | a_start),
 .tempo_idx(tempo_sel),
 .t16_tick(t16_tick),
 .t16_half(t16_half));
wire [10:0] rd_addr = a_busy ? a_raddr : g_raddr;
song_ram u_song(
  .clk(clk),
  .we(song_we),
  .waddr(song_waddr),
  .wdata(song_wdata),
  .raddr(rd_addr),
  .rdata(rd_rdata));
guide_player u_guide(
  .clk(clk),
  .rst(rst),
  .start(g_start),
  .song_id(g_song),
  .cnt_in(g_cnt),
  .stop(g_stop),
  .t16_tick(t16_tick),
  .raddr(g_raddr),
  .rdata(rd_rdata),
  .keys(key_all),
  .busy(g_busy),
  .target_keys(g_targets),
  .target_valid(g_valid),
  .urgent(g_urgent),
  .idx(g_idx),
  .total(g_total),
  .done(g_done),
  .hit_cnt(g_hit),
  .miss_cnt(g_miss),
  .strict(bt_strict));
auto_player u_auto(
  .clk(clk),
  .rst(rst),
  .start(a_start),
  .song_id(a_song),
  .cnt_in(bt_counts[9*a_song +: 9]),
  .stop(a_stop),
  .t16_tick(t16_tick),
  .t16_half(t16_half),
 .raddr(a_raddr),.rdata(rd_rdata),.auto_keys(auto_keys),
 .busy(a_busy),.idx(a_idx),.total(a_total),.done(a_done));
// ===========================================================================
//
// ===========================================================================
recorder u_rec(
  .clk(clk),
  .rst(rst),
  .keys(key_all),
  .rec_start(bt_rec_start),
  .rec_stop(bt_rec_stop),
  .t16_tick(t16_tick),
 .we(rec_we),
 .waddr(rec_waddr),
 .wdata(rec_wdata),
 .rec_busy(rec_busy),
 .rec_ready(rec_ready),
 .rec_full(rec_full),
 .rec_bytes(rec_bytes));
song_ram #(.WITH_INIT(0)) u_recram(
  .clk(clk),
  .we(rec_we),
  .waddr(rec_waddr),
  .wdata(rec_wdata),
  .raddr(bt_rec_raddr),
  .rdata(rec_rdata));

art_report u_rep(
  .clk(clk),
  .rst(rst),
  .touch_key(touch_key),
  .touch_ready(touch_ready),
  .touch_fault(touch_fault),
  .dist_mm(dist_mm),
  .rs_code(rs_code),
  .rs_ok(rs_ok),
  .dev_found(vl_dev_found),
  .touch2_key(touch_key2),
  .timbre(timbre_select),
  .select_mode(select_mode),
  .item(item),
  .enc_pos(enc_pos),
  .txd(uart_txd));
wire [47:0] led_bits;
wire [23:0] guide_mask=(g_valid && !test_mode)?g_targets:24'd0;
led_map #(.NKEY(24),.SPLIT(12),.SWAP_DIE(1)) u_lmap(
 .press((g_busy || g_done)?24'd0:(test_mode?key_eff:sounding)),
 .guide(guide_mask),.bits(led_bits));
tlc59282_chain #(
  .CLK_HZ(50000000),
  .REFRESH_HZ(1000),
  .N(48),
  .REVERSE(1)) u_tlc(
 .clk(clk),
 .rst(rst),
 .bits(led_bits),
 .sclk(tlc_clk),
 .sin(tlc_sin),
 .lat(tlc_lat),
 .bla(tlc_bla),
 .busy());
reg [5:0] voice_count;
integer j;
always @* begin
 voice_count=0;
 for(j=0;j<NB;j=j+1) voice_count=voice_count+active[j];
end
wire [7:0] display_status={test_mode,engine_clip,vl_dev_found,rs_ok,
 touch_fault2,touch_fault,touch_ready2,touch_ready};
rgb_scope #(.INSTRUMENT_PRESETS(INSTRUMENT_PRESETS),
.BACKLIGHT_ENABLE(LCD_BACKLIGHT_ENABLE),.TEST_PATTERN(LCD_TEST_PATTERN)) u_screen(
 .clk(clk),
 .rst(rst),
 .sample_valid(tick),
 .sample(audio_fx),
 .keys(test_mode?key_eff:sounding),   
 .voices(voice_count),
 .volume(test_mode?16'd32768:vol_q),
 .distance(dist_mm),.status(display_status),
 .item(item),
 .select_mode(select_mode),
 .test_mode(test_mode),
 .bt_song(bt_song),
 .bt_ready(bt_ready),
 .bt_state(bt_state),
 .bt_link(bt_link_ok),
 .bt_guide(play_busy),
 .bt_auto(a_busy|a_done),
 .bt_done(disp_done),
 .bt_total(disp_total),
 .g_targets(g_targets),
 .g_valid(g_valid),
 .g_hit(g_hit),
 .g_miss(g_miss),
 .g_urgent(g_urgent),
 .rec_busy(rec_busy),
 .rec_ready(rec_ready),
 .rec_full(rec_full),
 .rec_bytes(rec_bytes),
 .vibrato(test_mode?2'd0:vibrato),
 .timbre(test_mode?TONE_SAW:timbre_select),
 .delay_on(test_mode?1'b0:delay_on),
 .bend(test_mode?6'sd0:bend),
 .pclk(lcd_clk),
 .hs(lcd_hs),
 .vs(lcd_vs),
 .de(lcd_de),
 .backlight(lcd_bl),
 .red(lcd_r),
 .green(lcd_g),
 .blue(lcd_b));
(* syn_preserve = 1 *) reg [15:0] frame_cnt;
always @(posedge clk) begin
  if (rst)        frame_cnt <= 16'd0;
  else if (tick)  frame_cnt <= frame_cnt + 16'd1;
end
endmodule
