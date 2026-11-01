// score_roundtrip_tb —— 验证下载的乐谱真正写进了 song_ram
// 覆盖：不同槽位(1/2/3)与不同事件数(4/7/16/3)，含跨帧续传
// 判据：逐字节比对 RAM 与期望一致，song_counts 与 ready_mask 同步正确
module score_roundtrip_tb;
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

 task send_frame(input [7:0] cmd, input integer n, input [7:0] p0, input [7:0] p1,
                 input [7:0] p2, input [7:0] p3);
  reg [15:0] c;
  begin
   uart_byte(8'hA5); uart_byte(n[7:0]); uart_byte(cmd);
   c=crc16(16'hFFFF,n[7:0]); c=crc16(c,cmd);
   if(n>=1) begin uart_byte(p0); c=crc16(c,p0); end
   if(n>=2) begin uart_byte(p1); c=crc16(c,p1); end
   if(n>=3) begin uart_byte(p2); c=crc16(c,p2); end
   if(n>=4) begin uart_byte(p3); c=crc16(c,p3); end
   uart_byte(c[7:0]); uart_byte(c[15:8]);
  end
 endtask

 task send_data(input [7:0] seq, input integer ndat);
  reg [15:0] c; integer i; reg [7:0] len; reg [7:0] nb;
  begin
   nb  = ndat[7:0];
   len = nb + 8'd2;
   uart_byte(8'hA5); uart_byte(len); uart_byte(8'h02);
   c=crc16(16'hFFFF,len); c=crc16(c,8'h02);
   uart_byte(seq); c=crc16(c,seq);
   uart_byte(nb);  c=crc16(c,nb);
   for(i=0;i<ndat;i=i+1) begin uart_byte(dpl[i]); c=crc16(c,dpl[i]); end
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

 // 期望的字节流
 reg [7:0] dpl [0:39];
 reg [7:0] expect [0:511];
 integer errors=0;
 integer i,j,k2,base_slot;
 integer wr_count=0;

 always @(posedge clk) if(song_we) begin
  wr_count <= wr_count+1;
  if(wr_count<6) $display("  WR addr=%0d data=%0d", song_waddr, song_wdata);
 end

 always @(posedge clk) if(rx_vld)
  $display("  RX=0x%02X pst=%0d ast=%0d", rx_data_x, u_bt.pst, u_bt.ast);
 wire [7:0] rx_data_x = rx_byte;

 reg [2:0] ast_prev=0;
 always @(posedge clk) begin
  ast_prev <= u_bt.ast;
  if(ast_prev!==u_bt.ast)
   $display("  AST %0d -> %0d  cmd=0x%02X result=%0d act_n=%0d plen=%0d pbuf0=%0d pbuf1=%0d",
    ast_prev, u_bt.ast, u_bt.act_cmd, u_bt.act_result, u_bt.act_n, u_bt.plen,
    u_bt.pbuf[0], u_bt.pbuf[1]);
 end

 task do_case(input [1:0] slot, input integer nev);
  integer ev,bt,off,got;
  begin
   for(ev=0;ev<nev;ev=ev+1) begin
    expect[ev*4+0]=8'd 1;          // 低字节 bit0 表示 C4
    expect[ev*4+1]=8'd 0;
    expect[ev*4+2]=8'd 0;
    expect[ev*4+3]=8'd 8;          // 时长字节
   end
   // 下发 BEGIN 帧
   send_frame(8'h01,2,{6'd0,slot},nev[7:0],8'd0,8'd0); wait_idle;
   off=0; bt=0;
   while(off<nev) begin
    k2=(nev-off>8)?8:(nev-off);
    for(i=0;i<k2*4;i=i+1) dpl[i]=expect[off*4+i];
    send_data(bt[7:0], k2*4); wait_idle;
    off=off+k2; bt=bt+1;
   end
   // 下发 END 帧
   send_frame(8'h03,1,{6'd0,slot},8'd0,8'd0,8'd0); wait_idle;

   // 比对
   base_slot = slot*512;
   for(ev=0;ev<nev*4;ev=ev+1) begin
    got = u_song.mem[base_slot+ev];
    if(got !== expect[ev]) begin
     $display("  FAIL slot%0d byte[%0d] got=%0d want=%0d",slot,ev,got,expect[ev]);
     errors=errors+1;
    end
   end
   if(nev<20) begin
    got = u_song.mem[base_slot+nev*4];
    $display("  INFO slot%0d: byte right after end = %0d (残留，但 song_counts=%0d 限住了，不会读到)",
      slot, got, nev);
   end
   if(bt_counts[9*slot +: 9] !== nev) begin
    $display("  FAIL slot%0d counts=%0d want=%0d",slot,bt_counts[9*slot +: 9],nev);
    errors=errors+1;
   end
   if(!ready_mask[slot]) begin
    $display("  FAIL slot%0d not ready",slot); errors=errors+1;
   end
   $display("INFO slot%0d: %0d events written & verified",slot,nev);
  end
 endtask

 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(10) @(posedge clk);
  $display("INFO ready_mask=%b counts[0]=%0d", ready_mask, bt_counts[8:0]);

  // 用例：不同槽、不同事件数
  do_case(2'd1, 4);
  do_case(2'd2, 7);
  do_case(2'd3, 16);    // 正好两帧
  do_case(2'd1, 3);

  if(errors==0) $display("PASS score_roundtrip: download -> RAM contents & counts verified");
  else $display("FAILED %0d checks",errors);
  $finish;
 end
 initial begin #80000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
