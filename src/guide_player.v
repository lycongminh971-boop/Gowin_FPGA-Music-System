module guide_player (
 input  wire clk,
 input  wire rst,
 input  wire        start,
 input  wire [1:0]  song_id,
 input  wire [8:0]  cnt_in,
 input  wire        stop,
 input  wire        t16_tick,
 output reg  [10:0] raddr,
 input  wire [7:0]  rdata,
 input  wire [23:0] keys,
 output reg         busy,
 output reg  [23:0] target_keys,
 output reg         target_valid,
 output reg         urgent,
 output reg  [8:0]  idx,
 output reg  [8:0]  total,
 output reg         done,
 output reg  [8:0]  hit_cnt,     // 按对的事件数
 output reg  [8:0]  miss_cnt,
 //   1 = 严格节奏模式：到时限**强制前进并记 miss**，节奏完全由 BPM 决定
 input  wire        strict
);
localparam [3:0] G_IDLE=4'd0,G_ADV=4'd1,G_FK=4'd2,G_FD=4'd3,G_FH=4'd4,
                 G_GB=4'd5,G_GD=4'd6,G_WAIT=4'd7,G_REST=4'd8,
                 G_BLNK=4'd9;   // 2026-10-29: 命中后的「熄灭间隔」
reg [3:0]  gst;
reg [10:0] base;
reg [23:0] key_prev;
wire [23:0] key_rise = keys & ~key_prev;
wire [10:0] ra0 = base + {idx,2'b00};
reg [7:0] rem16;
reg [7:0] dur_r;
reg [7:0] klo,kmi,khi;          // 三个键位字节暂存
reg [23:0] hit_mask;            // 本事件已确认按过的键
reg        armed;
reg [23:0] stale;
reg [23:0] keys_at_hit;        // 命中那一刻按着的键（决定谁必须重按）
reg [23:0] blank_rise;         // 熄灭间隔里新按下的键（这些算下一格的命中）
wire [23:0] effective_keys = keys & ~stale;
wire        trig = |(key_rise & ~stale & target_keys);
wire        arm_now = armed | trig;
wire [23:0] hit_next = hit_mask | (arm_now ? (effective_keys & target_keys) : 24'd0);

always @(posedge clk) begin
 if(rst) begin
  gst<=G_IDLE;base<=0;key_prev<=0;
  raddr<=0;busy<=0;target_keys<=0;target_valid<=0;idx<=0;total<=0;done<=0;
  urgent<=0;rem16<=0;dur_r<=0;klo<=0;kmi<=0;khi<=0;
  hit_cnt<=0;miss_cnt<=0;hit_mask<=0;armed<=0;stale<=0;keys_at_hit<=0;blank_rise<=0;
 end else begin
  key_prev<=keys;
  stale<=stale & keys;
  if(stop) begin
   gst<=G_IDLE;busy<=1'b0;target_valid<=1'b0;done<=1'b0;urgent<=1'b0;
  end else if(start) begin
   base<={song_id,9'd0};          // 每首 512 字节
   idx<=9'd0;total<=cnt_in;
   busy<=1'b1;target_valid<=1'b0;done<=0;urgent<=0;
   hit_cnt<=9'd0;miss_cnt<=9'd0;
   hit_mask<=24'd0;armed<=1'b0;stale<=24'd0;keys_at_hit<=24'd0;blank_rise<=24'd0;
   gst<=G_ADV;
  end else if(busy) begin
   case(gst)
    G_ADV: begin
     if(idx>=total) begin
      busy<=1'b0;done<=1'b1;target_valid<=1'b0;urgent<=1'b0;gst<=G_IDLE;
     end else begin
      raddr<=ra0;                   // A0 = KEYS_LO
      gst<=G_FK;
     end
    end
    G_FK: begin raddr<=ra0+11'd1; gst<=G_FD; end
    G_FD: begin klo<=rdata; raddr<=ra0+11'd2; gst<=G_FH; end   // rdata = LO
    G_FH: begin kmi<=rdata; raddr<=ra0+11'd3; gst<=G_GB; end   // rdata = MID
    G_GB: begin khi<=rdata; gst<=G_GD; end                     // rdata = HI
    G_GD: begin
     rem16<=(rdata==8'd0)?8'd1:rdata;
     dur_r<=(rdata==8'd0)?8'd1:rdata;
     armed<=1'b0;
     if({khi,kmi,klo}==24'd0) begin
      target_valid<=1'b0; urgent<=1'b0;
      hit_mask<=24'd0;
      gst<=G_REST;
     end else begin
      target_keys<={khi,kmi,klo};
      target_valid<=1'b1;
      urgent<=1'b0;
      stale<=keys_at_hit & ~blank_rise;
      hit_mask<=blank_rise & {khi,kmi,klo};
      armed<=1'b0;
      gst<=G_WAIT;
     end
    end
    G_WAIT: begin
     hit_mask<=hit_next;
     armed<=arm_now;
     if(hit_next==target_keys) begin
      hit_cnt<=hit_cnt+1'b1;
      idx<=idx+1'b1;
      target_valid<=1'b0;
      urgent<=1'b0;
      keys_at_hit<=keys;
      blank_rise<=24'd0;
      gst<=G_BLNK;
     end else if(t16_tick) begin
      if(rem16>8'd1) begin
       rem16<=rem16-1'b1;
       urgent<=((rem16-8'd1)<=(dur_r>>1));
      end else if(strict) begin
       miss_cnt<=miss_cnt+1'b1;
       idx<=idx+1'b1;
       target_valid<=1'b0;
       urgent<=1'b0;
       gst<=G_ADV;
      end else begin
       urgent<=1'b1;
      end
     end
    end
    G_REST: begin
     target_valid<=1'b0;
     if(t16_tick) begin
      if(rem16<=8'd1) begin idx<=idx+1'b1; gst<=G_ADV; end
      else rem16<=rem16-1'b1;
     end
    end
     // ============================================================
     // G_BLNK：命中后的**熄灭间隔**（2026-10-29 新增）
     //
     //   用户反馈：连续两个同音事件（欢乐颂 E4 E4、两只老虎 C4 C4…）时，
     //   按第一下命中后，第二个事件立刻又点亮同一个键 ——
     //   看起来"灯根本没灭过"，只能靠连按时序去数，很困惑。
     //
     //   现在命中后先进入本状态：target_valid=0（灯全灭），
     //   等下一个 1/16 拍再前进并点亮下一格。
     //   => 视觉上就是「按一下 → 灭 → 再亮起」。
     //
     //   ⚠️ 为什么用 t16_tick 而不是固定时钟数：
     //     固定时钟数会让仿真跑几百万拍、极慢；用节拍脉冲则天然跟 BPM 走，
     //     TB 里手动给 tick1 也能精确控制。120BPM 时约 125ms，肉眼清晰可辨。
     G_BLNK: begin
      target_valid<=1'b0;
      urgent<=1'b0;
      blank_rise<=blank_rise | key_rise;   // 熄灭期间按下 = 为下一格做的准备
      if(t16_tick) gst<=G_ADV;      // 灯灭满一个 1/16 拍，再点亮下一格
     end
    default: gst<=G_IDLE;
   endcase
  end
 end
end
endmodule
