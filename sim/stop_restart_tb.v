// stop_restart_tb —— 验证停止后重播或切槽不会沿用上一次的播放状态。
// 覆盖 AUTO 停止、GUIDE 停止、停止后 PLAY 槽2 从头开始、AUTO 直接切槽2。
// 判据是 busy/keys 清零、idx=0、目标键属于新槽。

module stop_restart_tb;
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
 wire [2:0]  bt_tempo_sel; wire bt_tempo_vld; wire bt_strict;
 wire        bt_rec_start,bt_rec_stop; wire [10:0] bt_rec_raddr;
 wire [35:0] bt_counts;

 bt_link u_bt(.clk(clk),.rst(rst),
  .rx_data(rx_byte),.rx_valid(rx_vld),
  .tx_data(tx_byte),.tx_send(tx_send),.tx_busy(tx_busy),
  .song_we(song_we),.song_waddr(song_waddr),.song_wdata(song_wdata),
  .ready_mask(ready_mask),.link_ok(link_ok),.rx_done(rx_done),.rx_total(rx_total),
  .state(bt_state),.guide_start(bt_gstart),.guide_song(bt_gsong),.guide_stop(bt_gstop),
  .auto_start(bt_auto_start),.auto_song(bt_auto_song),
  .set_vld(bt_set_vld),.set_param(bt_set_param),.set_val(bt_set_val),
  .tempo_sel(bt_tempo_sel),.tempo_vld(bt_tempo_vld),.strict_rhythm(bt_strict),
  .cur_tempo(3'd3),
  .cur_tone(2'd0),.cur_bend(6'd0),.cur_vib(2'd0),.cur_delay(1'b0),
  .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),.rec_raddr(bt_rec_raddr),
  .rec_rdata(8'd0),.rec_busy(1'b0),.rec_ready(1'b0),.rec_full(1'b0),.rec_bytes(12'd0),
  .song_counts(bt_counts));

 // 曲谱槽
 wire [10:0] rd_addr;
 wire [7:0]  rd_rdata;
 wire [10:0] a_rd, g_rd;
 wire [7:0]  a_rdata, g_rdata;
 song_ram #(.WITH_INIT(0)) u_song(.clk(clk),.we(song_we),
  .waddr(song_waddr),.wdata(song_wdata),.raddr(rd_addr),.rdata(rd_rdata));

 // star.v 里的接线方式：AUTO 与 GUIDE 共享 rd_rdata，靠 mux 选地址
 reg t16=0, t16h=0;
 wire a_busy,a_done,g_busy,g_done,g_valid;
 wire [23:0] auto_keys, g_targets;
 wire [8:0] a_idx,a_total,g_idx,g_total;

 wire g_start = bt_gstart;
 wire a_start = bt_auto_start && !g_start;
 wire g_stop  = bt_gstop | a_start;
 // AUTO 在 g_start 或 bt_gstop 时停止。
 wire a_stop_real = g_start | bt_gstop;
 wire [1:0] g_song = bt_gstart ? bt_gsong : 2'd0;
 wire [1:0] a_song = bt_auto_start ? bt_auto_song : 2'd0;

 assign rd_addr = a_busy ? a_rd : g_rd;
 assign a_rdata = rd_rdata;
 assign g_rdata = rd_rdata;

 auto_player u_auto(.clk(clk),.rst(rst),
  .start(a_start),.song_id(a_song),.cnt_in(bt_counts[9*a_song +: 9]),.stop(a_stop_real),
  .t16_tick(t16),.t16_half(t16h),
  .raddr(a_rd),.rdata(a_rdata),.auto_keys(auto_keys),
  .busy(a_busy),.idx(a_idx),.total(a_total),.done(a_done));

 guide_player u_guide(.clk(clk),.rst(rst),
  .start(g_start),.song_id(g_song),.cnt_in(bt_counts[9*g_song +: 9]),.stop(g_stop),
  .t16_tick(t16),.raddr(g_rd),.rdata(g_rdata),.keys(24'd0),
  .busy(g_busy),.target_keys(g_targets),.target_valid(g_valid),.urgent(),
  .idx(g_idx),.total(g_total),.done(g_done),.hit_cnt(),.miss_cnt(),.strict(1'b0));

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
 reg [7:0] dpl [0:39];
 task send_data(input [7:0] seq, input integer ndat);
  reg [15:0] c; integer i; reg [7:0] len; reg [7:0] nb;
  begin
   nb=ndat[7:0]; len=nb+8'd2;
   uart_byte(8'hA5); uart_byte(len); uart_byte(8'h02);
   c=crc16(16'hFFFF,len); c=crc16(c,8'h02);
   uart_byte(seq); c=crc16(c,seq);
   uart_byte(nb);  c=crc16(c,nb);
   for(i=0;i<ndat;i=i+1) begin uart_byte(dpl[i]); c=crc16(c,dpl[i]); end
   uart_byte(c[7:0]); uart_byte(c[15:8]);
  end
 endtask
 task send1(input [7:0] cmd, input [7:0] p0);
  reg [15:0] c;
  begin
   uart_byte(8'hA5); uart_byte(8'd1); uart_byte(cmd);
   c=crc16(16'hFFFF,8'd1); c=crc16(c,cmd);
   uart_byte(p0); c=crc16(c,p0);
   uart_byte(c[7:0]); uart_byte(c[15:8]);
  end
 endtask
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
   while((tx_busy || u_bt.txst!=3'd0 || u_bt.ast!=3'd0) && n<400000) begin
    @(negedge clk); n=n+1;
   end
   repeat(3000) @(negedge clk);
  end
 endtask
 task tick1; begin t16=1; repeat(20) @(posedge clk); t16=0; repeat(200) @(posedge clk); end endtask

 integer errors=0;
 task chk(input cond, input [1023:0] msg);
  begin
   if(!cond) begin $display("  FAIL: %0s", msg); errors=errors+1; end
  end
 endtask

 integer e,i;
 task download(input [1:0] slot, input [7:0] keybit, input integer nev);
  integer k,bt2,o;
  begin
   send2(8'h01, {6'd0,slot}, nev[7:0]); wait_idle;
   o=0; bt2=0;
   while(o<nev) begin
    k=(nev-o>8)?8:(nev-o);
    for(i=0;i<k;i=i+1) begin dpl[i*4+0]=keybit; dpl[i*4+1]=8'd0; dpl[i*4+2]=8'd0; dpl[i*4+3]=8'd8; end
    send_data(bt2[7:0], k*4); wait_idle;
    o=o+k; bt2=bt2+1;
   end
   send1(8'h03, {6'd0,slot}); wait_idle;
  end
 endtask

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);

  // 槽1(song0) 用 key5(0x20)，槽2(song1) 用 key7(0x80)
  download(2'd0, 8'h20, 6);
  download(2'd1, 8'h80, 6);
  $display("INFO 下载完成 ready=%b counts0=%0d counts1=%0d", ready_mask, bt_counts[8:0], bt_counts[17:9]);

  // 用例1：AUTO 播放后 MODE0 停止
  send2(8'h07, 8'd2, 8'd0); wait_idle;
  tick1;
  chk(a_busy===1'b1, "AUTO 应在播放");
  chk(auto_keys===24'h000020, "AUTO 应发 key5");
  $display("INFO AUTO 播放中 keys=%06h idx=%0d", auto_keys, a_idx);

  send2(8'h07, 8'd0, 8'd0); wait_idle;   // 停止
  repeat(50) @(negedge clk);
  chk(a_busy===1'b0, "MODE0 后 AUTO 必须停");
  chk(auto_keys===24'h000000, "MODE0 后 auto_keys 必须清 0");
  chk(g_busy===1'b0, "MODE0 后 GUIDE 必须停");
  $display("INFO 停止后 a_busy=%b auto_keys=%06h g_busy=%b", a_busy, auto_keys, g_busy);

  // 用例2：停止后 PLAY 槽2 从头开始
  send1(8'h04, 8'd1); wait_idle;
  repeat(30) @(negedge clk);
  chk(g_busy===1'b1, "PLAY 槽2 后 GUIDE 应开始");
  chk(g_idx===9'd0, "PLAY 槽2 后 idx 必须为 0（从头）");
  chk(g_targets===24'h000080, "PLAY 槽2 的目标键应是 key7，而不是上一首的 key5");
  $display("INFO PLAY 槽2 后 idx=%0d target=%06h (want 0 / 000080)", g_idx, g_targets);

  // 用例3：GUIDE 播放中停止
  send2(8'h07, 8'd0, 8'd0); wait_idle;
  repeat(50) @(negedge clk);
  chk(g_busy===1'b0, "GUIDE 播放中 MODE0 必须停");
  chk(g_valid!==1'b1, "停止后不应还有目标键在亮");
  $display("INFO GUIDE 停止后 g_busy=%b valid=%b", g_busy, g_valid);

  // 用例4：AUTO 直接切槽2
  send2(8'h07, 8'd2, 8'd0); wait_idle;
  tick1;
  chk(auto_keys===24'h000020, "AUTO 槽1 应发 key5");
  send2(8'h07, 8'd2, 8'd1); wait_idle;   // 直接切到槽2
  tick1;
  chk(a_busy===1'b1, "切槽后 AUTO 应仍在播");
  chk(auto_keys===24'h000080, "切槽后 AUTO 应发 key7（槽2）");
  $display("INFO 切槽后 auto_keys=%06h idx=%0d", auto_keys, a_idx);

  if(errors==0) $display("PASS stop_restart: STOP 真停住了，停止后点槽会从头播该槽");
  else $display("FAILED %0d checks", errors);
  $finish;
 end
 initial begin #300000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule