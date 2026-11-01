module ec11_decode #(
 parameter integer CLK_HZ   = 50_000_000,
 parameter integer FILT_US  = 200,       // A/B 稳定窗口；200us 可滤掉绝大多数触点抖动
 parameter integer SW_MS    = 20,        // 按压开关去抖窗口
 parameter integer DETENT_Q = 2,         // 一个 detent 等于几个四分之一状态（EC11L1525G01 = 2）
 parameter integer INV_DIR  = 0          // 1 = 反转方向（上板发现反了改这里，别改接线）
)(
 input  wire clk,
 input  wire rst,
 input  wire io_a,
 input  wire io_b,
 input  wire io_sw,
 output reg  step,       // 1 个 clk 宽的脉冲：转过一格
 output reg  dir,        // 与 step 同拍有效：1 = 顺时针（A 超前 B），0 = 逆时针
 output reg  sw_level,   // 去抖后的按压电平：1 = 正在按住
 output reg  sw_press    // 1 个 clk 宽的脉冲：按下的那一瞬间
);
localparam integer FILT_CYC = (CLK_HZ/1_000_000)*FILT_US;   // 200us @50MHz = 10000
localparam integer SW_CYC   = (CLK_HZ/1_000)*SW_MS;         // 20ms  @50MHz = 100000

// ── L1：输入同步（打两拍，消除跨时钟域亚稳态）────────────────────────────────
(* syn_preserve=1 *) reg [1:0] a_sync = 2'b11;
(* syn_preserve=1 *) reg [1:0] b_sync = 2'b11;
(* syn_preserve=1 *) reg [1:0] s_sync = 2'b11;
always @(posedge clk) begin
 a_sync <= {a_sync[0], io_a};
 b_sync <= {b_sync[0], io_b};
 s_sync <= {s_sync[0], io_sw};
end
wire [1:0] raw_q = {a_sync[1], b_sync[1]};
reg [1:0] q_stable;
reg [1:0] raw_q_d;
reg [15:0] filt_cnt;
reg        q_upd;      // 稳定状态刚刚更新的那一拍
always @(posedge clk) begin
 if(rst) begin
  q_stable <= 2'b11;   // 上电默认停在 11（格雷序列里的中间态），避免首拍被判非法
  raw_q_d  <= 2'b11;
  filt_cnt <= 0;
  q_upd    <= 0;
 end else begin
  q_upd   <= 0;
  raw_q_d <= raw_q;
  if(raw_q != raw_q_d) begin
   filt_cnt <= 0;                       // 原始值又跳了：重新计时
  end else if(raw_q == q_stable) begin
   filt_cnt <= 0;                       // 已经一致：不用计时
  end else if(filt_cnt >= FILT_CYC-1) begin
   q_stable <= raw_q;
   filt_cnt <= 0;
   q_upd    <= 1;
  end else begin
   filt_cnt <= filt_cnt + 1'b1;
  end
 end
end
function [1:0] g2p;
 input [1:0] g;
 begin
  case(g)
   2'b00:   g2p = 2'd0;
   2'b01:   g2p = 2'd1;
   2'b11:   g2p = 2'd2;
   2'b10:   g2p = 2'd3;
   default: g2p = 2'd0;
  endcase
 end
endfunction

reg  [1:0]  q_prev;    // 上一次被接受的相位
reg  signed [3:0] acc; // 四分之一步累加器（-8..+7，吐格后立刻扣减，实际不会溢出）
localparam signed [3:0] LIM = DETENT_Q;   // 一个 detent 对应几个四分之一步
reg signed [3:0] acc_inc;
reg [1:0] q_prev_nxt;
always @* begin
 acc_inc    = 4'sd0;
 q_prev_nxt = q_prev;
 if(q_upd) begin
  // 判断这次跳变是不是格雷序上的相邻一步（只有相邻才是真旋转）
  if(g2p(q_stable) == ((q_prev + 2'd1) & 2'd3)) begin
   acc_inc    = 4'sd1;                       // 相位递增 = 顺时针
   q_prev_nxt = g2p(q_stable);
  end else if(g2p(q_stable) == ((q_prev - 2'd1) & 2'd3)) begin
   acc_inc    = -4'sd1;                      // 相位递减 = 逆时针
   q_prev_nxt = g2p(q_stable);
  end else begin
   // 两位同时改变：非法跳变（抖动或丢步）。只重同步，不计数。
   q_prev_nxt = g2p(q_stable);
  end
 end
end

always @(posedge clk) begin
 if(rst) begin
  q_prev <= 2'd2;
  acc    <= 4'sd0;
  step   <= 1'b0;
  dir    <= 1'b0;
 end else begin
  step   <= 1'b0;
  q_prev <= q_prev_nxt;
  // 吐格：累计到 ±LIM 就输出一个 step，并把已消费的部分扣掉
  if(acc + acc_inc >= LIM) begin
   acc  <= acc + acc_inc - LIM;
   step <= 1'b1;
   dir  <= INV_DIR ? 1'b0 : 1'b1;
  end else if(acc + acc_inc <= -LIM) begin
   acc  <= acc + acc_inc + LIM;
   step <= 1'b1;
   dir  <= INV_DIR ? 1'b1 : 1'b0;
  end else begin
   acc  <= acc + acc_inc;
  end
 end
end
wire sw_raw = ~s_sync[1];
reg  [19:0] sw_cnt;
always @(posedge clk) begin
 if(rst) begin
  sw_cnt   <= 0;
  sw_level <= 1'b0;
  sw_press <= 1'b0;
 end else begin
  sw_press <= 1'b0;
  if(sw_raw == sw_level) begin
   sw_cnt <= 0;                       // 已一致，不用计时
  end else if(sw_cnt >= SW_CYC[19:0]-1) begin
   sw_level <= sw_raw;
   sw_cnt   <= 0;
   if(sw_raw) sw_press <= 1'b1;       // 只在「按下」的跳变上出脉冲，松开不出
  end else begin
   sw_cnt <= sw_cnt + 1'b1;
  end
 end
end
endmodule
