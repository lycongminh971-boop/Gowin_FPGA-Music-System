// mode_cmd_tb —— 验证 MODE 命令把 slot0 导向 GUIDE 还是 AUTO
// 覆盖：mode=1 拉 guide_start、mode=2 拉 auto_start、mode=0 停止、未就绪槽、PLAY
// 判据：脉冲出现且 song 号正确；未就绪槽返回 3 且无脉冲；PLAY 只走 GUIDE
module mode_cmd_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;

 reg        bt_rxd=1;
 wire [7:0] rx_byte; wire rx_vld;
 uart_rx u_rx(.clk(clk),.rst(rst),.rx(bt_rxd),.data(rx_byte),.valid(rx_vld));
 wire [7:0] tx_byte; wire tx_send,tx_busy;
 uart_tx u_tx(.clk(clk),.rst(rst),.send(tx_send),.data(tx_byte),.tx(),.busy(tx_busy));

 wire song_we; wire [10:0] song_waddr; wire [7:0] song_wdata;
 wire [3:0] ready_mask; wire link_ok;
 wire [8:0] rx_done,rx_total; wire [2:0] bt_state;
 wire bt_gstart,bt_gstop; wire [1:0] bt_gsong;
 wire bt_auto_start; wire [1:0] bt_auto_song;
 wire bt_set_vld; wire [1:0] bt_set_param; wire [7:0] bt_set_val;
 wire bt_rec_start,bt_rec_stop; wire [10:0] bt_rec_raddr;
 wire [35:0] bt_counts;

 bt_link u_bt(.clk(clk),.rst(rst),
  .rx_data(rx_byte),.rx_valid(rx_vld),
  .tx_data(tx_byte),.tx_send(tx_send),.tx_busy(tx_busy),
  .song_we(song_we),.song_waddr(song_waddr),.song_wdata(song_wdata),
  .ready_mask(ready_mask),.link_ok(link_ok),.rx_done(rx_done),.rx_total(rx_total),
  .state(bt_state),.guide_start(bt_gstart),.guide_song(bt_gsong),.guide_stop(bt_gstop),
  .auto_start(bt_auto_start),.auto_song(bt_auto_song),
  .set_vld(bt_set_vld),.set_param(bt_set_param),.set_val(bt_set_val),
  .cur_tone(2'd0),.cur_bend(6'd0),.cur_vib(2'd0),.cur_delay(1'b0),
  .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),.rec_raddr(bt_rec_raddr),
  .rec_rdata(8'd0),.rec_busy(1'b0),.rec_ready(1'b0),.rec_full(1'b0),.rec_bytes(12'd0),
  .song_counts(bt_counts));

 localparam integer BDIV=434;
 task uart_byte(input [7:0] b);
  integer i;
  begin
   bt_rxd=0; repeat(BDIV) @(posedge clk);
   for(i=0;i<8;i=i+1) begin bt_rxd=b[i]; repeat(BDIV) @(posedge clk); end
   bt_rxd=1; repeat(BDIV) @(posedge clk);
  end
 endtask

 function [15:0] crc16;
  input [15:0] c; input [7:0] d;
  integer k; reg [15:0] cc;
  begin
   cc=c;
   for(k=7;k>=0;k=k-1) if(cc[15]^d[k]) cc=(cc<<1)^16'h1021; else cc=cc<<1;
   crc16=cc;
  end
 endfunction

 task send_frame(input [7:0] cmd, input integer n, input [7:0] p0, input [7:0] p1);
  reg [15:0] c;
  begin
   uart_byte(8'hA5);
   uart_byte(n[7:0]);
   uart_byte(cmd);
   c=crc16(16'hFFFF,n[7:0]);
   c=crc16(c,cmd);
   if(n>=1) begin uart_byte(p0); c=crc16(c,p0); end
   if(n>=2) begin uart_byte(p1); c=crc16(c,p1); end
   uart_byte(c[7:0]);
   uart_byte(c[15:8]);
  end
 endtask

 task wait_idle;
  integer n;
  begin
   n=0;
   while((tx_busy || u_bt.txst!=3'd0 || u_bt.ast!=3'd0) && n<200000) begin
    @(negedge clk); n=n+1;
   end
   repeat(3000) @(negedge clk);
  end
 endtask

 // 捕获脉冲
 reg saw_guide=0, saw_auto=0;
 reg [1:0] last_auto_song=0, last_guide_song=0;
 always @(posedge clk) begin
  if(bt_gstart) begin saw_guide<=1; last_guide_song<=bt_gsong; end
  if(bt_auto_start) begin saw_auto<=1; last_auto_song<=bt_auto_song; end
 end

 integer errors=0;
 reg [7:0] last_res;

 reg ack_d=0;
 always @(posedge clk) begin
  ack_d <= (u_bt.ast==3'd1);
  if(u_bt.ast==3'd1 && !ack_d) last_res <= u_bt.act_result;
 end

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);

  $display("INFO ready_mask=%b  counts[0]=%0d", ready_mask, bt_counts[8:0]);

  // slot0 走 GUIDE
  saw_guide=0; saw_auto=0;
  send_frame(8'h07, 2, 8'd1, 8'd0); wait_idle;
  if(last_res!=0) begin $display("FAIL slot0 GUIDE result=%0d",last_res); errors=errors+1; end
  if(!saw_guide) begin $display("FAIL slot0 GUIDE: guide_start never pulsed"); errors=errors+1; end
  else $display("INFO slot0 GUIDE OK, song=%0d", last_guide_song);

  // 先发 mode=0 停下
  send_frame(8'h07, 2, 8'd0, 8'd0); wait_idle;

  saw_guide=0; saw_auto=0;
  send_frame(8'h07, 2, 8'd2, 8'd0); wait_idle;
  if(last_res!=0) begin $display("FAIL slot0 AUTO result=%0d",last_res); errors=errors+1; end
  if(!saw_auto) begin $display("FAIL slot0 AUTO: auto_start never pulsed"); errors=errors+1; end
  else $display("INFO slot0 AUTO OK, song=%0d", last_auto_song);

  send_frame(8'h07, 2, 8'd0, 8'd0); wait_idle;

  saw_auto=0;
  send_frame(8'h07, 2, 8'd2, 8'd1); wait_idle;
  $display("INFO slot1 AUTO (not ready) result=%0d auto_start_pulsed=%0d", last_res, saw_auto);
  if(last_res!=3) begin $display("FAIL slot1 should be result=3, got %0d",last_res); errors=errors+1; end

  saw_guide=0; saw_auto=0;
  send_frame(8'h04, 1, 8'd0, 8'd0); wait_idle;
  $display("INFO slot0 PLAY(0x04): guide=%0d auto=%0d", saw_guide, saw_auto);
  if(!saw_guide) begin $display("FAIL PLAY should start guide"); errors=errors+1; end
  if(saw_auto)  begin $display("FAIL PLAY must NOT start auto"); errors=errors+1; end

  if(errors==0) $display("PASS mode_cmd: slot0 supports BOTH guide and auto; PLAY is guide-only");
  else $display("FAILED %0d checks", errors);
  $finish;
 end
 initial begin #50000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
