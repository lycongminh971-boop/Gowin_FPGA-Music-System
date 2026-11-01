// ===========================================================================
module vol_map #(
 //   D_FAR 700 → 400：可控行程从 600mm 缩到 300mm，手抬 20cm 就走到最小音量；
 //   V_SH  2   → 3  ：窗口内地板 25% → 12.5%，动态从 12dB 提到 18dB。
 parameter integer D_NEAR=100,D_FAR=400,VOL_SH=6,VMAX=32768,
 parameter integer SMOOTH_DIV=1024,
 parameter integer D_MIN=30,
 parameter integer HYST_MM=20,       // 出窗回滞，仅防边界抖动
 parameter integer LEAVE_CNT=5000000,   // 100ms：连续超远端多久判定"手走了"
 parameter integer VLD_GAP_CNT=20000000, // 400ms：多久没有任何新样本判定"链路断了"
 parameter integer GAMMA2=1,
 parameter integer V_SH=3,
 parameter integer V_MIN=(VMAX>>V_SH)
)(input wire clk,input wire rst,input wire [15:0] dist_mm,
 input wire dist_vld,input wire rs_ok,output wire [15:0] vol_q
);
localparam integer RANGE=D_FAR-D_NEAR;
localparam integer K=(VMAX*1024+RANGE/2)/RANGE;
localparam [16:0] NEAR_W=D_NEAR,FAR_W=D_FAR,RANGE_W=RANGE,MAX_W=VMAX;
localparam [16:0] MIN_W=D_MIN;
localparam [16:0] VMIN_W=V_MIN;
localparam [16:0] FAR_HYST_W=D_FAR-HYST_MM;   // 2026-10-28：回滞门限改到窗口**内侧**（回窗用）
// 显式定位宽常量：直接写 leave_cnt>=LEAVE_CNT[23:0] 对 integer 做位选在部分工具上
// 不合规（Verilog-2001 不允许对 integer 取位），这里先落到 localparam。
localparam [23:0] LEAVE_TOP=LEAVE_CNT;
localparam [24:0] GAP_TOP  =VLD_GAP_CNT;

// ---------------------------------------------------------------------------
// 一帧读数的三种身份判定（互斥）
//   honest   : 这一帧数值可信（有新样本 + range status 正常）
//   in_range : 落在可控窗口 [D_MIN, D_FAR) 内 —— 只有它能更新 target
//   far_away : 明确超出远端 —— 无论 rs_ok，8190 这类超量程值也算"手走了"
//   其余（too_near / honest 但 rs_ok=0 且 dist<D_FAR）= 无效读数 → 冻结
// ---------------------------------------------------------------------------
wire frame     = dist_vld;
wire honest    = dist_vld && rs_ok;
wire too_near  = dist_mm < MIN_W;
reg  track;
wire in_hi     = track ? (dist_mm < FAR_W) : (dist_mm < FAR_HYST_W);
wire in_range  = honest && !too_near && in_hi;
// far_away 不看 rs_ok：手拿走后传感器常回 rs_code≠11 + 8190 超量程，
// 若要求 rs_ok 才认定为"走了"，就正好漏掉真实的"手拿开"场景。
wire far_away  = frame && (dist_mm >= FAR_W);


wire [16:0] x=(dist_mm<=NEAR_W)?RANGE_W:(dist_mm>=FAR_W)?17'd0:FAR_W-{1'b0,dist_mm};
wire [48:0] y=x*K;
// 直线映射：y 是 x*K，K=VMAX*1024/RANGE，所以 y[26:10] 就是 x*VMAX/RANGE
wire [16:0] lin=(dist_mm<=NEAR_W)?MAX_W:(dist_mm>=FAR_W)?17'd0:y[26:10];

reg [16:0] lin_r;                                  // 切断 x*K → 曲线 的组合链
always @(posedge clk) begin
 if(rst) lin_r<=MAX_W;                             // 上电等同"贴手"，与 target/acc 初值一致
 else    lin_r<=lin;
end
// u ≥ 1/2 的判据：lin_r ∈ [0,32768]，所以"bit15 或 bit14 置位"就等价于 ≥16384。
//   写成比较器也行，但这条更省 LUT，且 32768 这个边界值只置 bit15，两个位或刚好覆盖。
wire        hi_half = lin_r[15] | lin_r[14];
wire [17:0] lin3    = {1'b0,lin_r} + {1'b0,lin_r,1'b0};        // 3*lin
wire [17:0] seg_hi  = (lin3 - {1'b0,MAX_W}) >> 1;              // (3*lin - VMAX)/2
wire [16:0] mapped_raw = GAMMA2 ? (hi_half ? seg_hi[16:0] : {1'b0,lin_r[16:1]}) : lin_r;
wire [16:0] mapped  = (V_MIN==0) ? mapped_raw
                    : (VMIN_W + mapped_raw - (mapped_raw>>V_SH));

reg far_state;
always @(posedge clk) begin
 if(rst) begin track<=0;far_state<=0;end
 else if(frame) begin
  if(in_range)      begin track<=1;far_state<=0;end
  else if(far_away) begin track<=0;far_state<=1;end
  // too_near / honest=0 且未超远端：track 与 far_state 都保持（冻结音量）
 end
end

// 连续超远端的 clk 计时（far_state 一旦回落立刻清零，故必须是"连续"）
reg [23:0] leave_cnt;
wire leave_hit = (leave_cnt>=LEAVE_TOP);
always @(posedge clk) begin
 if(rst) leave_cnt<=0;
 else if(!far_state) leave_cnt<=0;
 else if(!leave_hit) leave_cnt<=leave_cnt+1'b1;
end

// 断线看门狗：多久没见到任何新样本。单独一条路径，与"手移开"无关。
reg [24:0] vld_gap;
wire link_lost = (vld_gap>=GAP_TOP);
always @(posedge clk) begin
 if(rst || dist_vld) vld_gap<=0;
 else if(!link_lost) vld_gap<=vld_gap+1'b1;
end

// ---------------------------------------------------------------------------
// 目标锁存 + 一阶平滑
//   注意：acc 的更新条件**不能**挂 use_dist/in_range（第一版在此栽过）：
//   dist_vld 是单时钟脉冲，acc 每 SMOOTH_DIV(1024) 拍才更新一次，两者几乎
//   不可能同拍 ⇒ acc 被永久冻死。必须让 target 锁存与 acc 平滑解耦。
// ---------------------------------------------------------------------------
reg signed [17:0] target,acc;
reg [31:0] divider;
wire signed [17:0] err=target-acc;
wire signed [17:0] delta=err >>> VOL_SH;
// 冻结/恢复的优先级：窗口内跟随 > 手离开或断线 → 回默认 > 无效读数 → 保持
// 2026-10-22 注意 restore 必须与 far_state 相与：
//   leave_cnt 是在 far_state 回落后**下一拍**才清零的，若 restore 只看 leave_hit，
//   手回到窗口的那一拍 target 刚被写成 mapped，下一拍又会被 leave_hit 拉回 VMAX，
//   表现为"手回来了但音量一直是满的"（review_vol_tb 第一条实测抓到的正是这个）。
wire restore = (leave_hit && far_state) || link_lost;
always @(posedge clk) begin
 if(rst) begin target<=VMAX;acc<=VMAX;divider<=0;end
 else begin
  if(in_range)   target<=mapped;          // 有效窗口内：跟随距离
  else if(restore) target<=VMAX;          // 手确已离开 / 链路断开：平滑回默认满音量
  // 其余（短时无效读数）：target 保持不动
  if(divider>=SMOOTH_DIV-1) begin
   divider<=0;
   // 接近目标时精确到达，避免右移截断使满音量永远差几个 LSB。
   if(err < (1<<VOL_SH) && err > -(1<<VOL_SH)) acc<=target;
   else acc<=acc+delta;
  end else divider<=divider+1'b1;
 end
end
assign vol_q=acc[15:0];
endmodule
