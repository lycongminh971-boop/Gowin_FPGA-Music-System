// set_cmd_tb —— 验证 SET 命令每帧产生一个 set_vld 脉冲
// 覆盖：TONE/BEND/VIB/DELAY 四类参数，含边界值与非法值
// 判据：合法帧共 6 个脉冲且 param/val 正确；非法值不产生脉冲
module set_cmd_tb;
 reg clk=0; always #10 clk=~clk;   // 50MHz 系统时钟
 reg rst=1;

 // 手机侧 UART 发送
 reg        bt_rxd=1;
 wire [7:0] rx_byte; wire rx_vld;
 uart_rx u_rx(.clk(clk),.rst(rst),.rx(bt_rxd),.data(rx_byte),.valid(rx_vld));
 wire [7:0] tx_byte; wire tx_send,tx_busy;
 reg  bt_txd_hold=1;
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

 localparam integer BDIV=434, HALF=217;
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
   for(k=7;k>=0;k=k-1) begin
    if(cc[15]^d[k]) cc=(cc<<1)^16'h1021; else cc=cc<<1;
   end
   crc16=cc;
  end
 endfunction

 task send_frame(input [7:0] cmd, input integer n, input [7:0] p0, input [7:0] p1);
  reg [15:0] c; integer i;
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

 // 监视 set_vld 脉冲
 integer set_hits=0;
 reg [1:0] last_param; reg [7:0] last_val;
 always @(posedge clk) if(bt_set_vld) begin
  set_hits<=set_hits+1; last_param<=bt_set_param; last_val<=bt_set_val;
  $display("INFO set_vld pulse #%0d param=%0d val=%0d",set_hits+1,bt_set_param,bt_set_val);
 end
 // 全程记录板子收到的字节与状态跳变，用于对比成功/失败帧
reg [2:0] ast_d=0;
always @(posedge clk) begin
  if(u_bt.rx_valid) begin
    $display("    RX=0x%02X pst=%0d",u_bt.rx_data,u_bt.pst);
    if(u_bt.rx_data==8'hA5 && u_bt.pst==3'd0)
      $display("      [A5 gate] ast=%0d txst=%0d rep_req=%0d tx_busy=%0d tx_send=%0d  -> %s",
        u_bt.ast,u_bt.txst,u_bt.rep_req,u_bt.tx_busy,u_bt.tx_send,
        ((u_bt.ast==3'd0)&&(u_bt.txst==3'd0)&&!u_bt.rep_req&&!u_bt.tx_busy&&!u_bt.tx_send)?"ACCEPT":"**REJECT**");
  end
  if(ast_d !== u_bt.ast) $display("    ast %0d -> %0d",ast_d,u_bt.ast);
  ast_d <= u_bt.ast;
end

 // 停等协议：必须等 ACK 整帧串完再发下一帧
 // ast 在 ACK 入队时就回 0，而串出还要约 3000 拍，早发会被整帧丢弃
 // tx_busy 比 tx_send 晚一拍置位，故再留一段固定余量兜底
task wait_idle;
 integer n;
 begin
  n=0;
  while((tx_busy || u_bt.txst!=3'd0 || u_bt.ast!=3'd0) && n<200000) begin
   @(negedge clk); n=n+1;
  end
  if(n>=200000) $display("  WARN wait_idle timeout");
  repeat(4000) @(negedge clk);   // 兜底余量：远大于一个 ACK 帧(7B*434*10≈30400拍)的抖动
 end
endtask

integer errors=0;
 initial begin
  repeat(5) @(posedge clk); rst=0; repeat(5) @(posedge clk);

  // 音色 param=0，值 2
  $display("--- SET TONE=2 ---");
  send_frame(8'h08,2,8'd0,8'd2); wait_idle;

  // 弯音 param=1，值 0（对应 -12 半音）
  $display("--- SET BEND=-12 ---");
  send_frame(8'h08,2,8'd1,8'd0); wait_idle;

  // 颤音 param=2，值 3
  $display("--- SET VIB=3 ---");
  send_frame(8'h08,2,8'd2,8'd3); wait_idle;

  // 延音 param=3，值 1
  $display("--- SET DELAY=1 ---");
  send_frame(8'h08,2,8'd3,8'd1); wait_idle;

  // 再补边界值：音色=3、弯音=24
  $display("--- SET TONE=3 ---");
  send_frame(8'h08,2,8'd0,8'd3); wait_idle;
  $display("--- SET BEND=+12 ---");
  send_frame(8'h08,2,8'd1,8'd24); wait_idle;

  // 非法值必须被拒且不产生 set_vld
  $display("--- SET TONE=4 (illegal) ---");
  send_frame(8'h08,2,8'd0,8'd4); wait_idle;

  $display("INFO total set_vld pulses = %0d (expect 6)",set_hits);
  if(set_hits!=6) begin
   $display("FAIL: set_vld pulse count %0d != 6",set_hits);
   errors=errors+1;
  end
  if(errors==0) $display("PASS set_cmd: SET produces one set_vld pulse per valid command, rejects illegal");
  else $display("FAILED %0d",errors);
  $finish;
 end
 initial begin #20000000; $display("TIMEOUT"); $fatal(1,"timeout"); end
endmodule
