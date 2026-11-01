// slot_switch_tb —— 验证 AUTO 模式跟随 MODE 给出的曲目号
// 覆盖：song=0/1/2/0 四次切换，各槽 counts 由 force 预置
// 判据：auto_start 时刻抓到的 song 与 counts 与预置值一致
module slot_switch_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;

 reg        bt_rxd=1;
 wire [7:0] rx_byte; wire rx_vld;
 uart_rx u_rx(.clk(clk),.rst(rst),.rx(bt_rxd),.data(rx_byte),.valid(rx_vld));
 wire [7:0] tx_byte; wire tx_send,tx_busy;
 uart_tx u_tx(.clk(clk),.rst(rst),.send(tx_send),.data(tx_byte),.tx(),.busy(tx_busy));

 wire        song_we; wire [10:0] song_waddr; wire [7:0] song_wdata;
 wire [3:0]  ready_mask; wire link_ok;
 wire [8:0]  rx_done,rx_total; wire [2:0] bt_state;
 wire        bt_gstart,bt_gstop; wire [1:0] bt_gsong;
 wire        bt_auto_start; wire [1:0] bt_auto_song;
 wire        bt_set_vld; wire [2:0] bt_set_param; wire [7:0] bt_set_val;
 wire [2:0]  bt_tempo_sel; wire bt_tempo_vld;
 wire        bt_rec_start,bt_rec_stop; wire [10:0] bt_rec_raddr;
 wire [35:0] bt_counts;
 
 bt_link u_bt(.clk(clk),.rst(rst),
  .rx_data(rx_byte),.rx_valid(rx_vld),
  .tx_data(tx_byte),.tx_send(tx_send),.tx_busy(tx_busy),
  .song_we(song_we),.song_waddr(song_waddr),.song_wdata(song_wdata),
  .ready_mask(ready_mask),.link_ok(link_ok),.rx_done(rx_done),.rx_total(rx_total),
  .state(bt_state),.guide_start(bt_gstart),.guide_song(bt_gsong),
  .guide_stop(bt_gstop),
  .auto_start(bt_auto_start),.auto_song(bt_auto_song),
  .set_vld(bt_set_vld),.set_param(bt_set_param),.set_val(bt_set_val),
  .tempo_sel(bt_tempo_sel),.tempo_vld(bt_tempo_vld),.strict_rhythm(),.cur_tempo(3'd3),
  .cur_tone(2'd0),.cur_bend(6'd0),.cur_vib(2'd0),.cur_delay(1'b0),
  .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),.rec_raddr(bt_rec_raddr),
  .rec_rdata(8'd0),.rec_busy(1'b0),.rec_ready(1'b0),.rec_full(1'b0),.rec_bytes(12'd0),
  .song_counts(bt_counts));

 reg [1:0] bt_song=0;
 always @(posedge clk) begin
  if(rst) bt_song<=0;
  else begin
   if(bt_gstart)   bt_song<=bt_gsong;
   if(bt_auto_start) bt_song<=bt_auto_song;
  end
 end
 wire [1:0] a_song = bt_auto_start ? bt_auto_song : bt_song;
 wire [8:0] a_cnt  = bt_counts[9*a_song +: 9];

 reg [1:0] cap_song=0; reg [8:0] cap_cnt=0; reg cap_v=0;
 always @(posedge clk) if(bt_auto_start) begin
  cap_song <= a_song; cap_cnt <= a_cnt; cap_v <= 1'b1;
  $display("  AUTO start: a_song=%0d cnt=%0d", a_song, a_cnt);
 end

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

 task send2(input [7:0] cmd, input [7:0] p0, input [7:0] p1);
  reg [15:0] c;
  begin
   uart_byte(8'hA5); uart_byte(8'd2); uart_byte(cmd);
   c=crc16(16'hFFFF,8'd2); c=crc16(c,cmd);
   uart_byte(p0); c=crc16(c,p0);
   uart_byte(p1); c=crc16(c,p1);
   uart_byte(c[7:0]); uart_byte(c[15:8]);
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

 integer errors=0;
 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);
  force u_bt.ready_mask = 4'b0111;
  force u_bt.song_counts[8:0]    = 9'd62;
  force u_bt.song_counts[17:9]   = 9'd7;
  force u_bt.song_counts[26:18]  = 9'd8;
  repeat(4) @(posedge clk);

  $display("--- MODE AUTO song=0 ---");
  send2(8'h07, 8'd2, 8'd0); wait_idle;
  if(cap_song!==2'd0) begin $display("FAIL want song=0 got %0d",cap_song); errors=errors+1; end
  if(cap_cnt!==9'd62) begin $display("FAIL want cnt=62 got %0d",cap_cnt); errors=errors+1; end
  send2(8'h07, 8'd0, 8'd0); wait_idle;

  $display("--- MODE AUTO song=1 ---");
  send2(8'h07, 8'd2, 8'd1); wait_idle;
  if(cap_song!==2'd1) begin $display("FAIL want song=1 got %0d (换槽没生效)",cap_song); errors=errors+1; end
  if(cap_cnt!==9'd7) begin $display("FAIL want cnt=7 got %0d",cap_cnt); errors=errors+1; end
  send2(8'h07, 8'd0, 8'd0); wait_idle;

  $display("--- MODE AUTO song=2 ---");
  send2(8'h07, 8'd2, 8'd2); wait_idle;
  if(cap_song!==2'd2) begin $display("FAIL want song=2 got %0d",cap_song); errors=errors+1; end
  if(cap_cnt!==9'd8) begin $display("FAIL want cnt=8 got %0d",cap_cnt); errors=errors+1; end
  send2(8'h07, 8'd0, 8'd0); wait_idle;

  $display("--- MODE AUTO song=0 again ---");
  send2(8'h07, 8'd2, 8'd0); wait_idle;
  if(cap_song!==2'd0) begin $display("FAIL want song=0 got %0d",cap_song); errors=errors+1; end

  if(errors==0) $display("PASS slot_switch: AUTO follows MODE song id correctly");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #80000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
