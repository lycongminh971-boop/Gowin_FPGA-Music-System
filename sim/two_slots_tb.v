// two_slots_tb —— 验证两个曲谱槽分别下载后互不覆盖。
// A 曲 5 个事件写入 song0 槽，B 曲 9 个事件写入 song1 槽。
// 校验事件数、DUR 序列与 counts，确认两个槽内容各自保留。

module two_slots_tb;
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
  .state(bt_state),.guide_start(bt_gstart),.guide_song(bt_gsong),.guide_stop(bt_gstop),
  .auto_start(bt_auto_start),.auto_song(bt_auto_song),
  .set_vld(bt_set_vld),.set_param(bt_set_param),.set_val(bt_set_val),
  .tempo_sel(bt_tempo_sel),.tempo_vld(bt_tempo_vld),.cur_tempo(3'd3),
  .cur_tone(2'd0),.cur_bend(6'd0),.cur_vib(2'd0),.cur_delay(1'b0),
  .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),.rec_raddr(bt_rec_raddr),
  .rec_rdata(8'd0),.rec_busy(1'b0),.rec_ready(1'b0),.rec_full(1'b0),.rec_bytes(12'd0),
  .song_counts(bt_counts));

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

 task send_begin(input [1:0] slot, input [7:0] cnt);
  reg [15:0] c;
  begin
   uart_byte(8'hA5); uart_byte(8'd2); uart_byte(8'h01);
   c=crc16(16'hFFFF,8'd2); c=crc16(c,8'h01);
   uart_byte({6'd0,slot}); c=crc16(c,{6'd0,slot});
   uart_byte(cnt); c=crc16(c,cnt);
   uart_byte(c[7:0]); uart_byte(c[15:8]);
  end
 endtask

 task send_end(input [1:0] slot);
  reg [15:0] c;
  begin
   uart_byte(8'hA5); uart_byte(8'd1); uart_byte(8'h03);
   c=crc16(16'hFFFF,8'd1); c=crc16(c,8'h03);
   uart_byte({6'd0,slot}); c=crc16(c,{6'd0,slot});
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
 integer e,i,off;

 // 下载一首：按键固定 key0，DUR 用 dur_base 加偏移区分。
 task download(input [1:0] slot, input integer nev, input [7:0] dur_base);
  integer k,bt,o;
  begin
   send_begin(slot, nev[7:0]); wait_idle;
   o=0; bt=0;
   while(o<nev) begin
    k=(nev-o>8)?8:(nev-o);
    for(i=0;i<k;i=i+1) begin
     dpl[i*4+0]=8'd1;                 // LO = key0
     dpl[i*4+1]=8'd0;
     dpl[i*4+2]=8'd0;
     dpl[i*4+3]=dur_base+((o+i)%3);   // DUR 变化，便于区分两首
    end
    send_data(bt[7:0], k*4); wait_idle;
    o=o+k; bt=bt+1;
   end
   send_end(slot); wait_idle;
  end
 endtask

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);

  // A 曲写入 0 号槽，5 个事件，DUR = 8..10。
  $display("--- download A to slot0 ---");
  download(2'd0, 5, 8'd8);
  $display("  ready=%b counts[0]=%0d counts[1]=%0d", ready_mask, bt_counts[8:0], bt_counts[17:9]);

  // B 曲写入 1 号槽，9 个事件，DUR = 20..22。
  $display("--- download B to slot1 ---");
  download(2'd1, 9, 8'd20);
  $display("  ready=%b counts[0]=%0d counts[1]=%0d", ready_mask, bt_counts[8:0], bt_counts[17:9]);

  // 关键：0 号槽必须仍是那 5 个事件（DUR 8..10）。
  $display("--- verify slot0 still has A (5 events, DUR 8..10) ---");
  for(e=0;e<5;e=e+1) begin
   off = e*4;
   $display("  slot0[%0d] DUR=%0d (want %0d)", e, u_song.mem[off+3], 8+((e)%3));
   if(u_song.mem[off+3] !== (8+((e)%3))) begin
    $display("  FAIL slot0[%0d] DUR=%0d want %0d", e, u_song.mem[off+3], 8+((e)%3));
    errors=errors+1;
   end
  end
  if(bt_counts[8:0] !== 9'd5) begin $display("  FAIL counts[0]=%0d want 5",bt_counts[8:0]); errors=errors+1; end

  // 1 号槽必须是那 9 个事件（DUR 20..22）。
  $display("--- verify slot1 has B (9 events, DUR 20..22) ---");
  for(e=0;e<9;e=e+1) begin
   off = 512 + e*4;
   if(u_song.mem[off+3] !== (20+((e)%3))) begin
    $display("  FAIL slot1[%0d] DUR=%0d want %0d", e, u_song.mem[off+3], 20+((e)%3));
    errors=errors+1;
   end
  end
  if(bt_counts[17:9] !== 9'd9) begin $display("  FAIL counts[1]=%0d want 9",bt_counts[17:9]); errors=errors+1; end

  // 打印首字节对照
  $display("  slot0[0..3]=%0d %0d %0d %0d", u_song.mem[0],u_song.mem[1],u_song.mem[2],u_song.mem[3]);
  $display("  slot1[0..3]=%0d %0d %0d %0d", u_song.mem[512],u_song.mem[513],u_song.mem[514],u_song.mem[515]);

  if(errors==0) $display("PASS two_slots: two songs in different slots do NOT overwrite each other");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #120000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
