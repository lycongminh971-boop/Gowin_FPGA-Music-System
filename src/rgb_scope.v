module rgb_scope #(
 parameter INSTRUMENT_PRESETS=0, // 与合成引擎的预设开关保持一致。
 parameter H_ACTIVE=480,H_SYNC=4,H_BACK=39,H_FRONT=8,
 parameter V_ACTIVE=272,V_SYNC=4,V_BACK=8,V_FRONT=8,
 parameter HS_POL=0,VS_POL=0,BACKLIGHT_ENABLE=0,TEST_PATTERN=0, // 修改批注：上板可选静态彩条，隔离音频/字模问题。
 parameter TP_BLINK=0 // 1=彩条与全黑按帧交替（判"屏是否收到有效像素"），0=稳定诊断图案。
)(
 input wire clk,rst,sample_valid,
 input wire signed [15:0] sample,
 input wire [23:0] keys,
 input wire [5:0] voices,
 input wire [15:0] volume,distance,
 input wire [7:0] status,
 input wire [2:0] item,          // 当前编辑项 0=TONE 1=BEND 2=VIB 3=DELAY（2026-10-29 起只有这 4 项）
 input wire [1:0] bt_song,       // 选中的歌号 0..3
 input wire [3:0] bt_ready,      // 4 首各自的"已下载完成"
 input wire [2:0] bt_state,      // 0=IDLE 1=RXING 2=READY 3=ERROR
 input wire       bt_link,       // 心跳有效（手机还连着）
 input wire       bt_guide,      // 指引/自动演奏进行中（GUIDE 或 AUTO）
 input wire       bt_auto,       // 当前跑的是 AUTO（决定显示 A 还是 G 前缀）
 input wire [8:0] bt_done,       // 要显示的第一个数（下载已收音符 / 指引当前序号）
 input wire [8:0] bt_total,      // 要显示的第二个数
 input wire [23:0] g_targets,     // 指引目标键位掩码（复音：一个和弦可能点亮多个）
 input wire       g_valid,       // 目标键有效
 input wire [8:0] g_hit,         // 按对的音数
 input wire [8:0] g_miss,        // 超时漏掉的音数
 input wire       g_urgent,      // 剩余时值不足一半 → 目标键闪烁提示"该按了"
 // 演奏录音状态
 input wire       rec_busy,      // 正在录
 input wire       rec_ready,     // 录完且有内容，可以 COMMIT
 input wire       rec_full,      // 录满自动停了
 input wire [11:0] rec_bytes,    // 已录字节数（音符数 = 这个数 ÷ 2）
 input wire select_mode,         // 0=浏览 1=调整
 input wire test_mode,           // 测试模式（显示 TEST，参数被强制）
 input wire [1:0] vibrato,
 input wire [1:0] timbre,        // 0=SINE 1=SAW 2=SQUARE 3=TRI
 input wire delay_on,
 input wire signed [5:0] bend,
 output wire pclk,backlight,
 output reg hs,vs,de,
 output reg [5:0] red,green,blue
);
localparam HT=H_ACTIVE+H_SYNC+H_BACK+H_FRONT;
localparam VT=V_ACTIVE+V_SYNC+V_BACK+V_FRONT;
// 版面纵向分区（都是 y 的绝对行号）
localparam WAVE_TOP=40,WAVE_BOT=224,WAVE_MID=132;   // 波形区 40..223，零线 132
localparam KEY_TOP=232;                             // 24 键条 232..247
reg [2:0] divider;
reg [10:0] h,v;
reg pixel_clock;
assign pclk=pixel_clock; // 寄存器输出，避免计数器组合译码产生时钟毛刺
assign backlight=BACKLIGHT_ENABLE && !rst;
wire pixel_update=(divider==0);
wire frame_blank=pixel_update && h==0 && v==V_SYNC+V_BACK+V_ACTIVE;
// TP_BLINK=1 时让「彩条」与「全黑」约 1Hz 交替。
//   判据：屏若收到有效像素 → 会明显一明一暗地闪；
//         屏若处于"无信号默认态"（本屏实测为全白）→ 一直白，不会有任何变化。
//   取帧计数第 5 位：帧率 64.5Hz / 64 ≈ 1.008Hz，肉眼节奏合适。
//   默认 TP_BLINK=0：稳定图案才能看清边界与灰阶，闪黑反而毁掉判读。
reg [5:0] tp_cnt;
always @(posedge clk) begin
 if(rst) tp_cnt<=6'd0;
 else if(frame_blank) tp_cnt<=tp_cnt+1'b1;
end
wire tp_black = TP_BLINK && tp_cnt[5];
reg [7:0] wave_ram[0:1023];
reg front,ready,have_frame,capturing;
reg [8:0] wr;
reg [11:0] trigger_wait;
reg previous_negative;
wire [9:0] write_addr={!front,wr};
wire signed [17:0] wave_y = 18'sd132 - ($signed(sample)>>>8);
wire [7:0] wave_pix = (wave_y<18'sd40)?8'd40:((wave_y>18'sd223)?8'd223:wave_y[7:0]);
reg [7:0] wave_read;
reg [9:0] x,y;
always @* begin
 x=h-H_SYNC-H_BACK;
 y=v-V_SYNC-V_BACK;
end
always @(posedge clk) begin
 // 同步读 RAM，像素更新之间有 5 个系统时钟供读延迟
 wave_read<=wave_ram[{front,(x<480)?x[8:0]:9'd0}];
 if(rst) begin
  front<=0;ready<=0;have_frame<=0;capturing<=0;wr<=0;trigger_wait<=0;previous_negative<=0;
 end else begin
  if(frame_blank && ready) begin front<=~front;ready<=0;have_frame<=1;end
  if(sample_valid) begin
   previous_negative<=sample[15];
   if(!ready) begin
    if(!capturing) begin
     trigger_wait<=trigger_wait+1'b1;
     if((previous_negative && !sample[15]) || trigger_wait==4095) begin
      capturing<=1;wr<=0;trigger_wait<=0;
     end
    end else begin
     wave_ram[write_addr]<=wave_pix;
     if(wr==479) begin ready<=1;capturing<=0;end
     else wr<=wr+1'b1;
    end
   end
  end
 end
end

reg [23:0] key_frame;
reg [15:0] volume_frame,distance_frame;
reg [7:0] status_frame;
reg [2:0] item_frame;
reg [1:0] vibrato_frame,timbre_frame;
reg [1:0] bsong_f;
reg [3:0] bready_f;
reg [2:0] bstate_f;
reg blink_f,bguide_f,bauto_f;
reg [8:0] bdone_f,btot_f;
reg [23:0] gtgt_f;
reg gval_f;
reg [8:0] ghit_f,gmiss_f;
reg gurg_f;
reg brecb_f,brecrdy_f,brecfull_f;
reg [11:0] recb_f;
reg [4:0] blink_div;
reg blink2;
reg select_frame,delay_frame,test_frame;
reg signed [5:0] bend_frame;
always @(posedge clk) begin
 if(rst) begin
  key_frame<=0;volume_frame<=0;distance_frame<=0;status_frame<=0;
  item_frame<=0;vibrato_frame<=0;timbre_frame<=0;select_frame<=0;delay_frame<=0;
  bsong_f<=0;bready_f<=0;bstate_f<=0;blink_f<=0;bguide_f<=0;bauto_f<=0;bdone_f<=0;btot_f<=0;gtgt_f<=0;gval_f<=0;
  ghit_f<=0;gmiss_f<=0;gurg_f<=0;
  brecb_f<=0;brecrdy_f<=0;brecfull_f<=0;recb_f<=0;
  blink_div<=0;blink2<=0;
  test_frame<=0;bend_frame<=0;
 end else if(frame_blank) begin
  key_frame<=keys;volume_frame<=volume;distance_frame<=distance;
  status_frame<=status;item_frame<=item;vibrato_frame<=vibrato;timbre_frame<=timbre;
  bsong_f<=bt_song;bready_f<=bt_ready;bstate_f<=bt_state;blink_f<=bt_link;
  bguide_f<=bt_guide;bauto_f<=bt_auto;bdone_f<=bt_done;btot_f<=bt_total;gtgt_f<=g_targets;gval_f<=g_valid;
  ghit_f<=g_hit;gmiss_f<=g_miss;gurg_f<=g_urgent;
  brecb_f<=rec_busy;brecrdy_f<=rec_ready;brecfull_f<=rec_full;recb_f<=rec_bytes;
  blink_div<=blink_div+1'b1;
  if(blink_div==5'd24) begin blink_div<=5'd0;blink2<=~blink2; end
  select_frame<=select_mode;delay_frame<=delay_on;test_frame<=test_mode;bend_frame<=bend;
 end
end
reg [6:0] vol_pct;
reg [7:0] vol_ch2,vol_ch1,vol_ch0;
reg [7:0] dist_ch3,dist_ch2,dist_ch1,dist_ch0;
// 距离有效性：与 vol_map 的 use_dist 同口径（rs_ok + 器件在位 + 不在物理死区 + 不是 8190 超量程）。
// 无效就显示 ----，绝不把上一帧的旧值冒充有效测量。
wire dist_valid = status_frame[4] && status_frame[5]
               && (distance_frame>=16'd30) && (distance_frame<16'd8000);
always @(posedge clk) begin
 if(rst) begin
  vol_pct<=0;vol_ch2<="0";vol_ch1<="0";vol_ch0<="0";
  dist_ch3<="-";dist_ch2<="-";dist_ch1<="-";dist_ch0<="-";
 end else begin
  vol_pct<=(volume_frame*100)/32768;   // 100 必须是 32 位无尺寸常量，否则 16 位乘法会溢出
  // 2026-10-29：百位为 0 时显示空格，不再显示 "音量080%"。
  //   字段宽度仍固定 3 位（百位/十位/个位各一格），所以 "%" 不会左右跳。
  //   vol_pct 上限 100，所以百位只可能是 0 或 1，用比较代替除法更省。
  vol_ch2<=(vol_pct>=7'd100)?"1":" ";
  vol_ch1<="0"+vol_pct/10%10;
  vol_ch0<="0"+vol_pct%10;
  // 距离无效时整字段写 '----'，避免"旧值看起来像有效测量"
  if(dist_valid) begin
   // 千位为 0 时显示空格：300mm → "距 300毫米"，而不是"距0300毫米"
   dist_ch3<=(distance_frame>=16'd1000)?("0"+distance_frame/1000%10):" ";
   dist_ch2<="0"+distance_frame/100%10;
   dist_ch1<="0"+distance_frame/10%10;
   dist_ch0<="0"+distance_frame%10;
  end else begin
   dist_ch3<="-";dist_ch2<="-";dist_ch1<="-";dist_ch0<="-";
  end
 end
end
function [7:0] decch;           // 0..15 → '0'..'9'/'A'..'F'（只用低 4 位）
 input [3:0] n;
 begin decch = 8'h30 + {4'd0,n}; end
endfunction
function [15:0] tone_name;
 input [1:0] t;
 begin
  case(t)
   2'd0: tone_name=INSTRUMENT_PRESETS ? {8'h98,8'h99} : "SN";   // 长笛 / SINE
   2'd1: tone_name={8'h9A,8'h9B};                                // 锯齿 / SAW
   2'd2: tone_name=INSTRUMENT_PRESETS ? {8'h9C,8'h9D} : "SQ";   // 单簧 / SQUARE
   default: tone_name={8'h9E,8'h9F};                             // 三角 / TRI
  endcase
 end
endfunction
function [47:0] head_name;
 input s;
 begin head_name = s ? {8'h85,8'h93,"    "} : {8'h91,8'h92,"    "}; end
endfunction
function [47:0] item_field;
 input [2:0] it;
 begin
  case(it)
   3'd0: item_field={8'h82,8'h83,"    "};              // 音色
   3'd1: item_field={8'h84,8'h85,"    "};              // 变调
   3'd2: item_field={8'h86,8'h82,"    "};              // 颤音
   3'd3: item_field={8'h87,8'h88,"    "};              // 延时
   default: item_field={8'h82,8'h83,"    "};           // 音色（越界兜底，正常不可达）
  endcase
 end
endfunction
// 模式：正常 / 测试（原 NORMAL / TEST），定宽 6 格
function [47:0] mode_name;
 input tm;
 begin mode_name = tm ? {8'h94,8'h95,"    "} : {8'h96,8'h97,"    "}; end
endfunction
function [39:0] bend_val;
 input signed [5:0] bd;
 reg [5:0] a;
 begin
  a = bd[5] ? (-bd) : bd;       // 先取绝对值再拆位，避免对负数做除法
  bend_val = { bd[5] ? "-" : "+", decch(a/10), decch(a%10), 8'h8F, 8'h82 };
 end
endfunction
function [79:0] value_name;
 input [2:0] it;
 input [1:0] tm;
 input signed [5:0] bd;
 input [1:0] vb;
 input dl;
 begin
  case(it)
   // 音色：2 格名字 + 8 空格
   3'd0: value_name = {tone_name(tm), "        "};
   // 变调：5 格（+03半音）+ 5 空格
   3'd1: value_name = {bend_val(bd), "     "};
   3'd2: value_name = {decch({2'b00,vb}), "/3", "       "};
   3'd3: value_name = dl ? {8'h89,"         "} : {8'h8A,"         "};
   default: value_name = "          ";
  endcase
 end
endfunction
reg [7:0] bd_h,bd_t,bd_o,bt_h,bt_t,bt_o;
integer bdv,btv;
always @(posedge clk) begin
 if(rst) begin bd_h<="0";bd_t<="0";bd_o<="0";bt_h<="0";bt_t<="0";bt_o<="0";end
 else begin
  bdv=bdone_f;
  bd_h<="0"+bdv/100;bd_t<="0"+bdv/10%10;bd_o<="0"+bdv%10;
  btv=btot_f;
  bt_h<="0"+btv/100;bt_t<="0"+btv/10%10;bt_o<="0"+btv%10;
 end
end
reg [7:0] gh,gt,gm,gn;
integer ghv,gmv;
always @(posedge clk) begin
 if(rst) begin gh<="0";gt<="0";gm<="0";gn<="0";end
 else begin
  ghv=(ghit_f>9'd99)?99:ghit_f;
  gh<="0"+ghv/10; gt<="0"+ghv%10;
  gmv=(gmiss_f>9'd99)?99:gmiss_f;
  gm<="0"+gmv/10; gn<="0"+gmv%10;
 end
end
reg [7:0] tune_ch2,tune_ch1,tune_ch0;
reg [6:0] tpb;
reg [3:0] tdeg,toct;
reg [7:0] tlet;
always @(posedge clk) begin
 if(rst) begin tune_ch2<="-";tune_ch1<="-";tune_ch0<="-";end
 else if(frame_blank) begin
  tpb  = $signed(bend_frame) + 7'sd12;           // -12..+12 → 0..24
  tdeg = tpb % 12;                              // 0=C 1=#C 2=D ... 11=B
  toct = 4'd3 + tpb/12;                         // 3 / 4 / 5
  case(tdeg)
   4'd0,4'd1: tlet="C";
   4'd2,4'd3: tlet="D";
   4'd4:      tlet="E";
   4'd5,4'd6: tlet="F";
   4'd7,4'd8: tlet="G";
   4'd9,4'd10:tlet="A";
   default:   tlet="B";
  endcase
  if(tdeg[0]) begin
   tune_ch2<="#";tune_ch1<=tlet;tune_ch0<="0"+toct;
  end else begin
   tune_ch2<=tlet;tune_ch1<="0"+toct;tune_ch0<=" ";
  end
 end
end
reg [7:0] rn_h,rn_t,rn_o;
integer rnv;
always @(posedge clk) begin
 if(rst) begin rn_h<="0";rn_t<="0";rn_o<="0";end
 else begin
  rnv = recb_f[11:1];
  if(rnv>999) rnv=999;
  rn_h<="0"+rnv/100; rn_t<="0"+rnv/10%10; rn_o<="0"+rnv%10;
 end
end
wire [3:0] btcode =
  brecb_f   ? (brecfull_f ? 4'd9 : 4'd8) :
  brecrdy_f ? 4'd10 :
  bguide_f  ? (bauto_f ? 4'd7 : 4'd4) :
  (bstate_f==3'd3 ? 4'd5 : bstate_f==3'd1 ? 4'd2 :
  (bready_f[bsong_f] ? 4'd3 : (blink_f ? 4'd6 : 4'd0)));
reg [71:0] bt_val9;
always @* begin
 case(btcode)
  4'd0: bt_val9="NO DATA  "; // 心跳不是模块真实连接状态，不能据此断言蓝牙断开。
  // 4'd1 已不再产生（原来的 DATA OK 拆成了 RDY 和 --），保留分支防越界落到 G/A 前缀。
  4'd1,4'd6: bt_val9={"--  ",decch({2'b00,bsong_f}+4'd1),"/4","  "};
  4'd2: bt_val9={"RX",bd_h,bd_t,bd_o,"/",bt_h,bt_t,bt_o};
  4'd3: bt_val9={"RDY ",decch({2'b00,bsong_f}+4'd1),"/4","  "};
  4'd4,4'd7: bt_val9={bauto_f?"A":"G",bd_h,bd_t,bd_o,"/",bt_h,bt_t,bt_o," "};
  4'd5: bt_val9="RX ERROR ";
  // 录音中：REC + 已录音符数（三位，封顶 999）
  4'd8: bt_val9={"REC",rn_h,rn_t,rn_o,"   "};
  4'd9: bt_val9="REC FULL ";
  4'd10: bt_val9="REC RDY  ";
  default: bt_val9="NO DATA  ";
 endcase
end

reg [239:0] line0,line1,lineb;
always @(posedge clk) begin
 if(rst) begin
  line0<="                              ";
  line1<="                              ";
  lineb<="                              ";
 end else if(frame_blank) begin
  line0 <= {{8'h82,8'h83}, " ", tone_name(timbre_frame), "   ",
            {8'h86,8'h82}, " ", decch({2'b00,vibrato_frame}), "   ",
            {8'h87,8'h88}, " ", (delay_frame?8'h89:8'h8A), "   ",
            {8'h82,8'h8B}, vol_ch2, vol_ch1, vol_ch0, "%", "  "};
  line1 <= {head_name(select_frame), " ", item_field(item_frame), " ",
            value_name(item_frame,timbre_frame,bend_frame,vibrato_frame,delay_frame),
            mode_name(test_frame)};
  lineb <= {8'h8C,dist_ch3,dist_ch2,dist_ch1,dist_ch0,{8'h8D,8'h8E}," ",
            bt_val9," E",gh,gt,"L",gm,gn," ",
            {8'h82,8'h90},tune_ch2,tune_ch1,tune_ch0};   // 音域（0x90=域）
 end
end
// 像素通路：3 选 1 行 + 30 选 1 字节 + 一级寄存器 + 字模
reg [239:0] line_sel;
always @* begin
 case(y[8:4])
  5'd0 : line_sel=line0;
  5'd1 : line_sel=line1;
  5'd16: line_sel=lineb;
  default: line_sel=240'd0;      // 空白行，字模查表给 0
 endcase
end
wire [4:0] col_w=(x<480)?x[8:4]:5'd0;
wire [7:0] char_w=line_sel[8*(29-col_w) +: 8];
reg [9:0] h_r,v_r,x_r,y_r;
reg [7:0] character_r,wave_r;
reg [23:0] key_r;
reg have_r;
reg [4:0] ki_r;
reg xm20_r,xm48_r;
wire [9:0] xm20_w=x%20;
wire xm48_w=((x%48)==0);
wire [4:0] ki_w=(x<480)?(x/20):5'd0;
always @(posedge clk) begin
 if(rst) begin
  h_r<=0;v_r<=0;x_r<=H_ACTIVE;y_r<=V_ACTIVE; // 修改批注：流水线初值在消隐区，防止复位后首像素伪DE。
 character_r<=0;wave_r<=0;key_r<=0;have_r<=0;
  ki_r<=0;xm20_r<=0;xm48_r<=0;
 end else if(pixel_update) begin
  h_r<=h;v_r<=v;x_r<=x;y_r<=y;
  character_r<=char_w;wave_r<=wave_read;key_r<=key_frame;have_r<=have_frame;
  ki_r<=ki_w;
  xm20_r<=(xm20_w<10'd18);
  xm48_r<=xm48_w;
 end
end
wire glyph_r;
lcd_font u_font_r(.character(character_r),.row(y_r[3:0]),.col(x_r[3:0]),.pixel(glyph_r));

// 颜色：编辑态整行换色，并把选中项字段整块高亮
wire in_item_field = (x_r>=10'd112) && (x_r<10'd176);   // 列 7..10
wire [9:0] tp_seg = x_r/10'd60;                                 // 0..7
wire [5:0] tp_r6  = (x_r > 10'd126) ? 6'd63 : x_r[6:1];         // 0..63
wire [9:0] tp_xg  = x_r - 10'd160;
wire [9:0] tp_xb  = x_r - 10'd320;
wire [5:0] tp_g6  = (tp_xg > 10'd126) ? 6'd63 : tp_xg[6:1];     // 0..63
wire [5:0] tp_b6  = (tp_xb > 10'd126) ? 6'd63 : tp_xb[6:1];     // 0..63
reg [17:0] color;
always @* begin
 color={6'd2,6'd3,6'd6};
 if(y_r<10'd16)                 color={6'd5,6'd7,6'd12};  // 行1（声部/音色/延时/音量）
 else if(y_r<10'd32)            color={6'd8,6'd10,6'd16}; // 行2（浏览·调整/菜单项/参数）
 else if(y_r>=10'd256)          color={6'd5,6'd6,6'd11};  // 底行（距离/状态/节奏）
 // 顶栏下边线：2px，把"状态栏"和波形区硬分开。纯装饰，不参与任何译码。
 if(y_r>=10'd32 && y_r<10'd34)  color={6'd10,6'd14,6'd24};
 // --- 波形区 ---
 if(y_r>=WAVE_TOP && y_r<WAVE_BOT) begin
  color={6'd3,6'd5,6'd9};
  if(xm48_r)              color={6'd7,6'd9,6'd13};       // 竖网格
  if(y_r==WAVE_MID)       color={6'd12,6'd16,6'd22};     // 零线
  if(have_r && (y_r==wave_r || y_r==wave_r+1)) color={6'd0,6'd63,6'd40};  // 波形
 end
 // --- 24 键条：每键 20px，实心 18px ---
 if(y_r>=KEY_TOP && y_r<KEY_TOP+16 && xm20_r) begin
  color=key_r[ki_r]?{6'd63,6'd40,6'd0}:{6'd15,6'd15,6'd18};
  if(gval_f && gtgt_f[ki_r])
   color=(gurg_f && blink2)?{6'd31,6'd26,6'd0}:{6'd63,6'd55,6'd0}; // 与实体黄色提示灯一致
 end
 // --- 文字 ---
 if(glyph_r) begin
  if(y_r<32)        color = select_frame ? {6'd63,6'd50,6'd0} : {6'd55,6'd58,6'd63};
  else if(y_r>=256) color = {6'd50,6'd56,6'd62};
 end
 if(select_frame && y_r>=16 && y_r<32 && in_item_field) begin
  color = {6'd52,6'd36,6'd0};
  if(glyph_r) color = {6'd8,6'd5,6'd0};
 end
 if(TEST_PATTERN) begin
  if(tp_black) begin
   color=18'd0;                                   // TP_BLINK=1 时的全黑半周期
  end else begin
   // --- 竖彩条 ---
   case(tp_seg)
    10'd0: color={6'd63,6'd63,6'd63};             // 白
    10'd1: color={6'd63,6'd63,6'd0};              // 黄
    10'd2: color={6'd0,6'd63,6'd63};              // 青
    10'd3: color={6'd0,6'd63,6'd0};               // 绿
    10'd4: color={6'd63,6'd0,6'd63};              // 品红
    10'd5: color={6'd63,6'd0,6'd0};               // 红
    10'd6: color={6'd0,6'd0,6'd63};               // 蓝
    default: color=18'd0;                         // 黑
   endcase
   // --- 灰阶条：8 档 0/9/18/27/36/45/54/63，与彩条同分界 ---
   if(y_r>=10'd224 && y_r<10'd248) begin
    case(tp_seg)
     10'd0: color={6'd0,6'd0,6'd0};
     10'd1: color={6'd9,6'd9,6'd9};
     10'd2: color={6'd18,6'd18,6'd18};
     10'd3: color={6'd27,6'd27,6'd27};
     10'd4: color={6'd36,6'd36,6'd36};
     10'd5: color={6'd45,6'd45,6'd45};
     10'd6: color={6'd54,6'd54,6'd54};
     default:color={6'd63,6'd63,6'd63};
    endcase
   end
   // --- R/G/B 渐变：0..159 红，160..319 绿，320..479 蓝 ---
   if(y_r>=10'd248) begin
    if(x_r<10'd160)      color={tp_r6,6'd0,6'd0};
    else if(x_r<10'd320) color={6'd0,tp_g6,6'd0};
    else                 color={6'd0,6'd0,tp_b6};
   end
   // --- 外圈 2px 白框：压在所有图案之上，用来看有效区边界 ---
   if(x_r<10'd2 || x_r>=10'd478 || y_r<10'd2 || y_r>=10'd270)
    color={6'd63,6'd63,6'd63};
  end
 end
end

always @(posedge clk) begin
 if(rst) begin pixel_clock<=0;divider<=0;h<=0;v<=0;hs<=~HS_POL;vs<=~VS_POL;de<=0;red<=0;green<=0;blue<=0;end
 else begin
  divider<=(divider==4)?0:divider+1'b1;
  if(divider==2) pixel_clock<=1;
  else if(divider==4) pixel_clock<=0;
  // 输出在 divider=0 阶段更新，pclk 上升沿在 3 阶段，保证数据建立时间
  if(pixel_update) begin
   // HS/VS/DE 与颜色取自同一组延迟后的坐标，保证图形与同步严格对齐
   hs<=(h_r<H_SYNC)?HS_POL:!HS_POL;
   vs<=(v_r<V_SYNC)?VS_POL:!VS_POL;
   de<=(x_r<H_ACTIVE && y_r<V_ACTIVE);
   {red,green,blue}<=(x_r<H_ACTIVE && y_r<V_ACTIVE)?color:18'd0;
   if(h==HT-1) begin h<=0;v<=(v==VT-1)?0:v+1'b1;end
   else h<=h+1'b1;
  end
 end
end
endmodule
