module recorder #(
 parameter integer AW    = 11,
 parameter integer DEPTH = 2048
)(
 input  wire clk,
 input  wire rst,
 input  wire [23:0] keys,
 input  wire rec_start,            
 input  wire rec_stop,
 input  wire t16_tick,             // 1/16 拍脉冲，录音量化基准
 output reg  we,
 output reg  [AW-1:0] waddr,
 output reg  [7:0]    wdata,
 output reg  rec_busy,
 output reg  rec_ready,
 output reg  rec_full,             // 1=录满自动停了
 output reg  [AW:0] rec_bytes
);
localparam [1:0] R_IDLE = 2'd0,   // 空闲
                 R_GAP  = 2'd1,
                 R_HOLD = 2'd2,   // 按住计时
                 R_WR   = 2'd3;  

reg [1:0]  st;
reg [23:0] cur_keys;              // 当前事件涉及的全部键（不是单个键！）
reg [7:0]  dur;                   // 已计 1/16 拍数 0..127
reg [7:0]  dur_lat;
reg [1:0]  wr_ph;
reg        resume_hold;
reg        finish;

reg        rest_mode;
reg        pend_valid;            // 写休止期间用户已经按下，写完后要接着录这个音
reg [23:0] pend_keys;
reg        started;               // 是否已录到过第一个音（0=开头静音不计休止）

// 还有地方放一个完整事件（4 字节）吗
wire can_write = (rec_bytes <= (DEPTH-4));
wire [7:0] dur_fin = (dur == 8'd0) ? 8'd1 : dur;
wire still_down = |(keys & cur_keys);

always @(posedge clk) begin
 if(rst) begin
  st<=R_IDLE; cur_keys<=24'd0; dur<=8'd0; dur_lat<=8'd1;
  wr_ph<=2'd0; resume_hold<=1'b0; finish<=1'b0;
  rest_mode<=1'b0; pend_valid<=1'b0; pend_keys<=24'd0; started<=1'b0;
  we<=1'b0; waddr<={AW{1'b0}}; wdata<=8'd0;
  rec_busy<=1'b0; rec_ready<=1'b0; rec_full<=1'b0; rec_bytes<={(AW+1){1'b0}};
 end else begin
  we<=1'b0;

  case(st)
   // ------------------------------------------------------------------ IDLE
   R_IDLE: begin
    if(rec_start) begin
     rec_bytes <= {(AW+1){1'b0}};
     rec_ready <= 1'b0;
     rec_full  <= 1'b0;
     rec_busy  <= 1'b1;
     dur       <= 8'd0;
     wr_ph     <= 2'd0;
     cur_keys  <= 24'd0;
     rest_mode <= 1'b0;
     pend_valid<= 1'b0;
     started   <= 1'b0;
     st        <= R_GAP;
    end
   end

   // ------------------------------------------------------------------ GAP
   R_GAP: begin
    if(!can_write) begin
     // 录满：手上这个休止也塞不进去了，直接收摊
     rec_full  <= 1'b1;
     rec_busy  <= 1'b0;
     rec_ready <= 1'b1;
     st        <= R_IDLE;
    end else if(rec_stop) begin
     //   末尾那段静音只是"按下停止"的手松时间，记进去会让回放多出一截空等。
     rec_busy  <= 1'b0;
     rec_ready <= (rec_bytes != {(AW+1){1'b0}});
     st        <= R_IDLE;
    end else if(keys != 24'd0) begin
      // 有键按下：
      //   · 前面有静音 且 已经录过音 => 先把静音落成休止，再回来录这个音
      //   · 否则（开头静音 / 无静音）=> 直接进 HOLD，按下即起计
      //   之间的时间不该变成曲谱里的一个休止事件，那会让回放开头多一截静默。
      if(started && dur != 8'd0) begin
       rest_mode  <= 1'b1;
       cur_keys   <= 24'd0;
       dur_lat    <= dur;
       finish     <= 1'b0;
       resume_hold<= 1'b0;
       pend_valid <= 1'b1;
       pend_keys  <= keys;
       wr_ph      <= 2'd0;
       st         <= R_WR;
      end else begin
       cur_keys   <= keys;
       dur        <= 8'd0;
       started    <= 1'b1;          // 从这一刻起，静音才需要计休止
       st         <= R_HOLD;
      end
     end else if(t16_tick) begin
      // 静音计时：到 127 就先落一条，接着继续计（长静音拆成多条）
      if(started) begin
       if(dur >= 8'd127) begin
        rest_mode  <= 1'b1;
        cur_keys   <= 24'd0;
        dur_lat    <= 8'd127;
        finish     <= 1'b0;
        resume_hold<= 1'b0;
        pend_valid <= 1'b0;
        wr_ph      <= 2'd0;
        st         <= R_WR;
       end else begin
        dur <= dur + 8'd1;
       end
      end
     end
   end
   // ------------------------------------------------------------------ HOLD
   R_HOLD: begin
    cur_keys <= cur_keys | keys;
    if(!can_write) begin
     rec_full  <= 1'b1;
     rec_busy  <= 1'b0;
     rec_ready <= 1'b1;
     st        <= R_IDLE;
    end else if(rec_stop) begin
     dur_lat     <= dur_fin;
     resume_hold <= 1'b0;
     finish      <= 1'b1;
     wr_ph       <= 2'd0;
     st          <= R_WR;
    end else if(!still_down) begin
     dur_lat     <= dur_fin;
     resume_hold <= 1'b0;
     finish      <= 1'b0;
     wr_ph       <= 2'd0;
     st          <= R_WR;
    end else if(t16_tick) begin
     if(dur >= 8'd127) begin
      dur_lat     <= 8'd127;
      resume_hold <= 1'b1;
      finish      <= 1'b0;
      wr_ph       <= 2'd0;
      st          <= R_WR;
     end else begin
      dur <= dur + 8'd1;
     end
    end
   end

   // -------------------------------------------------------------------- WR
   R_WR: begin
    case(wr_ph)
     2'd0: begin
      we    <= 1'b1;
      waddr <= rec_bytes[AW-1:0];
      wdata <= cur_keys[7:0];
      wr_ph <= 2'd1;
     end
     2'd1: begin
      we    <= 1'b1;
      waddr <= rec_bytes[AW-1:0] + 1'b1;
      wdata <= cur_keys[15:8];
      wr_ph <= 2'd2;
     end
     2'd2: begin
      we    <= 1'b1;
      waddr <= rec_bytes[AW-1:0] + 2'd2;
      wdata <= cur_keys[23:16];
      wr_ph <= 2'd3;
     end
     default: begin
      we        <= 1'b1;
      waddr     <= rec_bytes[AW-1:0] + 2'd3;
      wdata     <= dur_lat;
      rec_bytes <= rec_bytes + {{(AW-2){1'b0}},3'b100};
      wr_ph     <= 2'd0;
      // ---- 鍐冲畾钀藉畬鐩樺幓鍝? ----
      if(finish) begin
       rec_busy  <= 1'b0;
       rec_ready <= 1'b1;              // 走到这里必然写了至少一个事件
       st        <= R_IDLE;
      end else if(resume_hold) begin
       dur <= 8'd0;
       st  <= R_HOLD;
      end else if(rest_mode) begin
       // 刚落完的是一条休止（空帧）
       rest_mode <= 1'b0;
       dur       <= 8'd0;
       if(pend_valid) begin
        // 写休止期间用户已经按下了 => 接着录这个音，别把它丢了
        cur_keys   <= pend_keys;
        pend_valid <= 1'b0;
        st         <= R_HOLD;
       end else begin
        st <= R_GAP;                   // 继续等下一个音，继续计静音
       end
      end else begin
       dur <= 8'd0;
       st  <= R_GAP;                   // 普通音符落完 => 回到等待+计静音
      end
     end
    endcase
   end

   default: st <= R_IDLE;
  endcase
 end
end
endmodule
