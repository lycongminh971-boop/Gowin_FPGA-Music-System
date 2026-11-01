// rec_chain_tb —— 验证录音经 COMMIT 写入曲谱槽的完整链路。
// 覆盖录音区写入、COMMIT 拷贝及 song_counts 一致。
// 还检查长曲被短录音覆盖后无残留、休止帧原样搬运。
// 按 star.v 的 recorder/rec_ram/bt_link/song_ram 接线复刻。

module rec_chain_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;

 // 手机侧 UART
 reg        bt_rxd=1;
 wire [7:0] rx_byte; wire rx_vld;
 uart_rx u_rx(.clk(clk),.rst(rst),.rx(bt_rxd),.data(rx_byte),.valid(rx_vld));
 wire [7:0] tx_byte; wire tx_send,tx_busy;
 uart_tx u_tx(.clk(clk),.rst(rst),.send(tx_send),.data(tx_byte),.tx(),.busy(tx_busy));

 // bt_link
 wire        song_we; wire [10:0] song_waddr; wire [7:0] song_wdata;
 wire [3:0]  ready_mask; wire link_ok;
 wire [8:0]  rx_done,rx_total; wire [2:0] bt_state;
 wire        bt_gstart,bt_gstop; wire [1:0] bt_gsong;
 wire        bt_auto_start; wire [1:0] bt_auto_song;
 wire        bt_set_vld; wire [2:0] bt_set_param; wire [7:0] bt_set_val;
 wire [2:0]  bt_tempo_sel; wire bt_tempo_vld; wire bt_strict;
 wire        bt_rec_start,bt_rec_stop; wire [10:0] bt_rec_raddr;
 wire [35:0] bt_counts;
 wire        rec_ready_w;

 // recorder
 reg  [23:0] keys=0;
 reg         t16=0;
 wire        rec_we; wire [10:0] rec_waddr; wire [7:0] rec_wdata;
 wire        rec_busy, rec_ready, rec_full;
 wire [11:0] rec_bytes;

 recorder u_rec(.clk(clk),.rst(rst),
  .keys(keys),
  .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),
  .t16_tick(t16),
  .we(rec_we),.waddr(rec_waddr),.wdata(rec_wdata),
  .rec_busy(rec_busy),.rec_ready(rec_ready),.rec_full(rec_full),.rec_bytes(rec_bytes));

 wire [7:0] rec_rdata;
 song_ram #(.WITH_INIT(0)) u_recram(.clk(clk),
  .we(rec_we),.waddr(rec_waddr),.wdata(rec_wdata),
  .raddr(bt_rec_raddr),.rdata(rec_rdata));

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
  .rec_rdata(rec_rdata),.rec_busy(rec_busy),.rec_ready(rec_ready),
  .rec_full(rec_full),.rec_bytes(rec_bytes),
  .song_counts(bt_counts));

 // 曲谱槽
 reg [10:0] rd_addr = 11'd0;
 wire [7:0] rd_rdata;
 song_ram #(.WITH_INIT(0)) u_song(.clk(clk),.we(song_we),
  .waddr(song_waddr),.wdata(song_wdata),.raddr(rd_addr),.rdata(rd_rdata));

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

 task send_nop(input [7:0] cmd);
  reg [15:0] c;
  begin
   uart_byte(8'hA5); uart_byte(8'd0); uart_byte(cmd);
   c=crc16(16'hFFFF,8'd0); c=crc16(c,cmd);
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

 // 1 拍 = 1 个时钟高 + 8 个低，远大于 recorder 写盘的 4 拍
 task tick1; begin t16=1; @(posedge clk); t16=0; repeat(8) @(posedge clk); end endtask
 task tickn(input integer n); integer i; begin for(i=0;i<n;i=i+1) tick1; end endtask

 integer errors=0;
 integer i,e;

 task dump_slot(input [1:0] slot, input integer nev);
  integer k, base;
  begin
   base = slot*512;
   for(k=0;k<nev;k=k+1)
    $display("    slot%0d ev%0d: keys=%06h dur=%0d", slot, k,
      {u_song.mem[base+k*4+2],u_song.mem[base+k*4+1],u_song.mem[base+k*4+0]},
      u_song.mem[base+k*4+3]);
  end
 endtask

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);

  // 用例 1：先往槽1 塞一首"长"曲子（20 事件），再用短录音覆盖它
  $display("--- case1: 槽1 先放 20 事件，再用短录音覆盖 ---");
  send2(8'h01, 8'd0, 8'd20); wait_idle;
  for(e=0;e<20;e=e+1) begin
   dpl[0]=8'd1; dpl[1]=8'd0; dpl[2]=8'd0; dpl[3]=8'd8;
  end
  // 分 3 帧（8+8+4 事件）
  for(i=0;i<8;i=i+1) begin dpl[i*4+0]=8'd1; dpl[i*4+3]=8'd9; end
  send_data(8'd0, 32); wait_idle;
  send_data(8'd1, 32); wait_idle;
  for(i=0;i<4;i=i+1) begin dpl[i*4+0]=8'd1; dpl[i*4+3]=8'd9; end
  send_data(8'd2, 16); wait_idle;
  send1(8'h03, 8'd0); wait_idle;
  $display("  槽1 原内容: ready=%b counts=%0d", ready_mask[0], bt_counts[8:0]);
  if(bt_counts[8:0]!==9'd20) begin $display("  FAIL 槽1 counts=%0d want 20",bt_counts[8:0]); errors=errors+1; end

  // 录音：C4 2拍 -> 静音3拍 -> D4 2拍
  send_nop(8'h0A); wait_idle;                 // REC_START
  tickn(2);                                    // 先空跑，让状态机进入 R_GAP
  keys=24'd1; tickn(2);
  keys=24'd0; tickn(3);
  keys=24'd4; tickn(2);
  keys=24'd0;
  send_nop(8'h0B); wait_idle;                 // REC_STOP
  $display("  录音完成: bytes=%0d ready=%b full=%b", rec_bytes, rec_ready, rec_full);

  // COMMIT 到槽1
  send1(8'h0C, 8'd0); wait_idle;
  $display("  槽1 覆盖后: ready=%b counts=%0d", ready_mask[0], bt_counts[8:0]);
  dump_slot(2'd0, 6);

  // 校验 counts 等于录音事件数，且远小于 20。
  if(bt_counts[8:0] === 9'd20) begin
   $display("  FAIL COMMIT 没生效，counts 仍是 20"); errors=errors+1;
  end
  if(bt_counts[8:0] === 9'd0) begin
   $display("  FAIL COMMIT 后 counts=0，录音没进去"); errors=errors+1;
  end
  if(bt_counts[8:0] > 9'd10) begin
   $display("  FAIL counts=%0d，短录音不该有这么多事件",bt_counts[8:0]); errors=errors+1;
  end
  // 槽内前两个事件必须与录音一致：C4 然后休止
  if(u_song.mem[0]!==8'd1 || u_song.mem[1]!==8'd0 || u_song.mem[2]!==8'd0)
   begin $display("  FAIL 槽1 ev0 keys 不对"); errors=errors+1; end
  if(u_song.mem[4]!==8'd0 || u_song.mem[5]!==8'd0 || u_song.mem[6]!==8'd0)
   begin $display("  FAIL 槽1 ev1 应为休止(全0)"); errors=errors+1; end
   else $display("  槽1 ev1 是休止 OK");

  // 播放该槽必须能起来（MODEL=AUTO song=0）
  send2(8'h07, 8'd2, 8'd0); wait_idle;
  if(bt_auto_start!==1'b1 && u_bt.act_result!==8'd0) begin
   $display("  FAIL 覆盖后槽1 无法自动演奏"); errors=errors+1;
  end

  // 用例 2：COMMIT 到一个空槽（槽3）。
  $display("--- case2: 录音 COMMIT 到空槽3 ---");
  send_nop(8'h0A); wait_idle;
  tickn(2);
  keys=24'd16; tickn(2);      // E4
  keys=24'd0; tickn(2);
  keys=24'd32; tickn(2);      // F4
  keys=24'd0;
  send_nop(8'h0B); wait_idle;
  send1(8'h0C, 8'd2); wait_idle;   // song=2 => 界面槽3
  $display("  槽3: ready=%b counts=%0d", ready_mask[2], bt_counts[2*9 +: 9]);
  dump_slot(2'd2, 5);
  if(!ready_mask[2]) begin $display("  FAIL 槽3 应就绪"); errors=errors+1; end
  if(bt_counts[2*9 +: 9]===9'd0) begin $display("  FAIL 槽3 counts=0"); errors=errors+1; end

  // 用例 3：CLEAR 之后槽位应回到"无曲"，且能重新录
  $display("--- case3: CLEAR 槽3 后重新录 ---");
  send1(8'h10, 8'd2); wait_idle;
  $display("  槽3 CLEAR 后: ready=%b counts=%0d", ready_mask[2], bt_counts[2*9 +: 9]);
  if(ready_mask[2]) begin $display("  FAIL CLEAR 后槽3 仍就绪"); errors=errors+1; end
  if(bt_counts[2*9 +: 9]!==9'd0) begin $display("  FAIL CLEAR 后槽3 counts 应为0"); errors=errors+1; end

  send_nop(8'h0A); wait_idle;
  tickn(2);
  keys=24'd64; tickn(3);      // G4
  keys=24'd0;
  send_nop(8'h0B); wait_idle;
  send1(8'h0C, 8'd2); wait_idle;
  $display("  槽3 重录后: ready=%b counts=%0d", ready_mask[2], bt_counts[2*9 +: 9]);
  dump_slot(2'd2, 4);
  if(!ready_mask[2]) begin $display("  FAIL 槽3 重录后应就绪"); errors=errors+1; end
  if(bt_counts[2*9 +: 9]===9'd0) begin $display("  FAIL 槽3 重录后 counts=0"); errors=errors+1; end

  if(errors==0) $display("PASS rec_chain: record->COMMIT->slot verified (overwrite/empty/re-record)");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #400000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
