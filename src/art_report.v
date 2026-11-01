module art_report #(
 parameter integer CLK_HZ    = 50_000_000,
 parameter integer BAUD      = 115200,
 parameter integer PERIOD_MS = 100
)(
 input  wire        clk,
 input  wire        rst,           // 高有效
 // ---- 来自 mpr121 #1 ----
 input  wire [11:0] touch_key,
 input  wire        touch_ready,
 input  wire        touch_fault,
 // ---- 来自 vl53l0x ----
 input  wire [15:0] dist_mm,
 input  wire [3:0]  rs_code,
 input  wire        rs_ok,
 input  wire        dev_found,
 // ---- 2026-10-20 新增 ----
 input  wire [11:0] touch2_key,    // mpr121 #2（按键板 2，ELE0..11）
 input  wire [1:0]  timbre,        // 当前音色编号 0=SINE 1=SAW 2=SQUARE 3=TRI
 input  wire        select_mode,   // 0=浏览 1=调整
 input  wire [2:0]  item,          // 当前编辑项 0=TONE 1=BEND 2=VIB 3=DELAY 4=BT 5=AUTO
 input  wire [7:0]  enc_pos,       // 旋钮累计位置
 // ---- 物理层 ----
 output reg         txd            // 空闲为高，直接接 FPGA TX 脚
);
localparam integer BDIV = CLK_HZ/BAUD;            // 50MHz/115200 = 434（实际 115207，误差 0.006%）
localparam integer PDIV = (CLK_HZ/1000)*PERIOD_MS;// 100ms = 5_000_000 拍
localparam integer LINE_LEN = 53;                 // 含 CR LF 的总字节数

// ---------------- 上报节拍 ----------------
reg [31:0] ptmr;
wire fire = (ptmr >= PDIV-1);
always @(posedge clk) ptmr <= rst ? 32'd0 : (fire ? 32'd0 : ptmr + 32'd1);
reg [11:0] K = 12'd0;
reg        R = 1'b0, F = 1'b0, O = 1'b0, V = 1'b0;
reg [15:0] D = 16'd0;
reg  [3:0] S = 4'd0;
reg [11:0] N = 12'd0;
reg  [3:0] T = 4'd0, G = 4'd0;
reg  [7:0] E = 8'd0;
always @(posedge clk) if (fire) begin
 K <= touch_key; R <= touch_ready; F <= touch_fault;
 D <= dist_mm;   S <= rs_code;     O <= rs_ok;      V <= dev_found;
 N <= touch2_key; T <= {2'b00,timbre};  G <= {select_mode,item};  E <= enc_pos;
end

// ---------------- 字节内容 ----------------
function [7:0] hx;                                // 4 bit → '0'..'9','A'..'F'
 input [3:0] v;
 begin hx = (v < 4'd10) ? (8'h30 + v) : (8'h37 + v); end
endfunction
function [7:0] b1;                                // 1 bit → '0' / '1'
 input v;
 begin b1 = v ? 8'h31 : 8'h30; end
endfunction
function [7:0] byte_at;
 input [5:0] i;
 begin
  case (i)
   6'd0 : byte_at = 8'h4B;                        // 'K'
   6'd1 : byte_at = 8'h3D;                        // '='
   6'd2 : byte_at = hx(K[11:8]);
   6'd3 : byte_at = hx(K[7:4]);
   6'd4 : byte_at = hx(K[3:0]);
   6'd5 : byte_at = 8'h20;                        // ' '
   6'd6 : byte_at = 8'h52;                        // 'R'
   6'd7 : byte_at = 8'h3D;
   6'd8 : byte_at = b1(R);
   6'd9 : byte_at = 8'h20;
   6'd10: byte_at = 8'h46;                        // 'F'
   6'd11: byte_at = 8'h3D;
   6'd12: byte_at = b1(F);
   6'd13: byte_at = 8'h20;
   6'd14: byte_at = 8'h44;                        // 'D'
   6'd15: byte_at = 8'h3D;
   6'd16: byte_at = hx(D[15:12]);
   6'd17: byte_at = hx(D[11:8]);
   6'd18: byte_at = hx(D[7:4]);
   6'd19: byte_at = hx(D[3:0]);
   6'd20: byte_at = 8'h20;
   6'd21: byte_at = 8'h53;                        // 'S'
   6'd22: byte_at = 8'h3D;
   6'd23: byte_at = hx(S);
   6'd24: byte_at = 8'h20;
   6'd25: byte_at = 8'h4F;                        // 'O'
   6'd26: byte_at = 8'h3D;
   6'd27: byte_at = b1(O);
   6'd28: byte_at = 8'h20;
   6'd29: byte_at = 8'h56;                        // 'V'
   6'd30: byte_at = 8'h3D;
   6'd31: byte_at = b1(V);
   6'd32: byte_at = 8'h20;
   6'd33: byte_at = 8'h4E;                        // 'N'  mpr121 #2
   6'd34: byte_at = 8'h3D;
   6'd35: byte_at = hx(N[11:8]);
   6'd36: byte_at = hx(N[7:4]);
   6'd37: byte_at = hx(N[3:0]);
   6'd38: byte_at = 8'h20;
   6'd39: byte_at = 8'h54;                        // 'T'  timbre
   6'd40: byte_at = 8'h3D;
   6'd41: byte_at = hx(T);
   6'd42: byte_at = 8'h20;
   6'd43: byte_at = 8'h47;                        // 'G'  菜单状态
   6'd44: byte_at = 8'h3D;
   6'd45: byte_at = hx(G);
   6'd46: byte_at = 8'h20;
   6'd47: byte_at = 8'h45;                        // 'E'  encoder position
   6'd48: byte_at = 8'h3D;
   6'd49: byte_at = hx(E[7:4]);
   6'd50: byte_at = hx(E[3:0]);
   6'd51: byte_at = 8'h0D;                        // CR
   6'd52: byte_at = 8'h0A;                        // LF
   default: byte_at = 8'h00;
  endcase
 end
endfunction
//发送状态机
reg [15:0] bc;
reg  [3:0] bi;                                    // 本字节已发到第几位
reg  [5:0] mi;                                  
reg        busy;
reg  [7:0] cur;
wire bd_end = (bc == BDIV-1);

always @(posedge clk) begin
 if (rst) begin
  txd <= 1'b1; busy <= 1'b0; bc <= 16'd0; bi <= 4'd0; mi <= 6'd1; cur <= 8'd0;
 end
 else if (busy) begin
  if (bd_end) begin
   bc <= 16'd0;
   if (bi == 4'd9) begin                          // 停止位也发完了
    if (mi == LINE_LEN) begin busy <= 1'b0; txd <= 1'b1; end   // 整行结束，回到空闲高
    else begin cur <= byte_at(mi); mi <= mi + 6'd1; bi <= 4'd0; txd <= 1'b0; end
   end
   else begin
    txd <= (bi < 4'd8) ? cur[bi[2:0]] : 1'b1;
    bi  <= bi + 4'd1;
   end
  end
  else bc <= bc + 16'd1;
 end
 else if (fire) begin                             // 发起一次整行发送
  cur <= byte_at(6'd0); mi <= 6'd1; busy <= 1'b1; bc <= 16'd0; bi <= 4'd0;
  txd <= 1'b0;                                    // 起始位立即拉低
 end
end
endmodule
