// clear_cmd_tb —— 验证 CLEAR 命令清除槽位后的状态
// 覆盖：单槽清除、全部清除、清除后 MODE/PLAY 返回 3、重新下载恢复
// 判据：返回 0 且 ready_mask 与 counts 归零；未就绪槽的 MODE/PLAY 返回 3
module clear_cmd_tb;
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
  .tempo_sel(bt_tempo_sel),.tempo_vld(bt_tempo_vld),.strict_rhythm(),.cur_tempo(3'd3),
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

 task send_nopayload(input [7:0] cmd);
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
   while((tx_busy || u_bt.txst!=3'd0 || u_bt.ast!=3'd0) && n<200000) begin
    @(negedge clk); n=n+1;
   end
   repeat(3000) @(negedge clk);
  end
 endtask

 reg [7:0] last_res;
 reg ack_d=0;
 always @(posedge clk) begin
  ack_d <= (u_bt.ast==3'd1);
  if(u_bt.ast==3'd1 && !ack_d) last_res <= u_bt.act_result;
 end

 integer errors=0;
 integer i;

 task download(input [1:0] slot, input integer nev);
  integer k,bt,o;
  begin
   send2(8'h01, {6'd0,slot}, nev[7:0]); wait_idle;
   o=0; bt=0;
   while(o<nev) begin
    k=(nev-o>8)?8:(nev-o);
    for(i=0;i<k;i=i+1) begin
     dpl[i*4+0]=8'd1; dpl[i*4+1]=8'd0; dpl[i*4+2]=8'd0; dpl[i*4+3]=8'd8;
    end
    send_data(bt[7:0], k*4); wait_idle;
    o=o+k; bt=bt+1;
   end
   send1(8'h03, {6'd0,slot}); wait_idle;
  end
 endtask

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);

  download(2'd0, 5);
  $display("INFO after download slot0: ready=%b counts[0]=%0d", ready_mask, bt_counts[8:0]);
  if(!ready_mask[0]) begin $display("FAIL slot0 should be ready"); errors=errors+1; end
  if(bt_counts[8:0]!==9'd5) begin $display("FAIL counts[0]=%0d",bt_counts[8:0]); errors=errors+1; end

  send2(8'h07, 8'd2, 8'd0); wait_idle;
  if(last_res!==8'd0) begin $display("FAIL MODE on ready slot should be 0, got %0d",last_res); errors=errors+1; end
  send2(8'h07, 8'd0, 8'd0); wait_idle;

  // CLEAR 单个槽位 song=0
  send1(8'h10, 8'd0); wait_idle;
  $display("INFO after CLEAR slot0: ready=%b counts[0]=%0d", ready_mask, bt_counts[8:0]);
  if(last_res!==8'd0) begin $display("FAIL CLEAR should return 0, got %0d",last_res); errors=errors+1; end
  if(ready_mask[0]) begin $display("FAIL slot0 should NOT be ready after CLEAR"); errors=errors+1; end
  if(bt_counts[8:0]!==9'd0) begin $display("FAIL counts[0] should be 0 after CLEAR, got %0d",bt_counts[8:0]); errors=errors+1; end

  send2(8'h07, 8'd2, 8'd0); wait_idle;
  $display("INFO MODE after clear: result=%0d (want 3)", last_res);
  if(last_res!==8'd3) begin $display("FAIL MODE on cleared slot should be 3, got %0d",last_res); errors=errors+1; end

  send1(8'h04, 8'd0); wait_idle;
  if(last_res!==8'd3) begin $display("FAIL PLAY on cleared slot should be 3, got %0d",last_res); errors=errors+1; end

  download(2'd0, 3);
  $display("INFO re-download: ready=%b counts[0]=%0d", ready_mask, bt_counts[8:0]);
  if(!ready_mask[0]) begin $display("FAIL slot0 should be ready again"); errors=errors+1; end
  if(bt_counts[8:0]!==9'd3) begin $display("FAIL counts[0]=%0d want 3",bt_counts[8:0]); errors=errors+1; end

  // CLEAR 全部槽位（无 payload）
  download(2'd1, 2);
  download(2'd2, 2);
  $display("INFO before CLEAR all: ready=%b", ready_mask);
  send_nopayload(8'h10); wait_idle;
  $display("INFO after CLEAR all: ready=%b", ready_mask);
  if(ready_mask!==4'b0000) begin $display("FAIL all ready should be 0, got %b",ready_mask); errors=errors+1; end
  if(bt_counts!==36'd0) begin $display("FAIL all counts should be 0"); errors=errors+1; end

  if(errors==0) $display("PASS clear_cmd: CLEAR clears ready/counts and blocks MODE/PLAY, re-download works");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #160000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
