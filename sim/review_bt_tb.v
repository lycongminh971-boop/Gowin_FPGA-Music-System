`timescale 1ns/1ps
// review_bt_tb —— 蓝牙串口协议与曲谱下载/引导播放回归。
// 覆盖：BEGIN/DATA/END 下载、CRC（含已知向量）、QUERY→STATUS 回帧、GUIDE/STOP、REC_COMMIT。
// 判据：坏 CRC、非法长度/时值/计数、错 seq、重复 DATA、越界 END 都必须被拒且不改动已存曲谱。
// 探针：直接读 u_song.mem 与 u_bt.wr_idx/exp_seq/act_result 做白盒核对。
module review_bt_tb;
reg clk=0;always #10 clk=~clk;      // 50MHz
reg rst=1;
reg bt_rxd=1;
wire bt_txd;

// 被测模块与连线
wire [7:0] rx_byte; wire rx_vld;
uart_rx u_rx(.clk(clk),.rst(rst),.rx(bt_rxd),.data(rx_byte),.valid(rx_vld));
wire [7:0] tx_byte; wire tx_send,tx_busy;
uart_tx u_tx(.clk(clk),.rst(rst),.send(tx_send),.data(tx_byte),.tx(bt_txd),.busy(tx_busy));
wire        song_we; wire [10:0] song_waddr; wire [7:0] song_wdata;
wire [3:0]  ready_mask;
wire        link_ok;
wire [8:0]  rx_done,rx_total;
wire [2:0]  bt_state;
wire        bt_gstart,bt_gstop;
wire [1:0]  bt_gsong;
wire [35:0] bt_counts;
// 录音侧端口：供 COMMIT 曲长用例驱动
wire        bt_auto_start, bt_set_vld;
wire [1:0]  bt_auto_song, bt_set_param;
wire [7:0]  bt_set_val;
wire        bt_rec_start, bt_rec_stop;
wire [10:0] bt_rec_raddr;
wire [7:0]  rec_rdata=8'd0;
reg         rec_ready=0;
reg  [11:0] rec_bytes=12'd0;
bt_link u_bt(.clk(clk),.rst(rst),
 .rx_data(rx_byte),.rx_valid(rx_vld),
 .tx_data(tx_byte),.tx_send(tx_send),.tx_busy(tx_busy),
 .song_we(song_we),.song_waddr(song_waddr),.song_wdata(song_wdata),
 .ready_mask(ready_mask),.link_ok(link_ok),.rx_done(rx_done),.rx_total(rx_total),
 .state(bt_state),.guide_start(bt_gstart),.guide_song(bt_gsong),
 .guide_stop(bt_gstop),.song_counts(bt_counts),
 .auto_start(bt_auto_start),.auto_song(bt_auto_song),
 .set_vld(bt_set_vld),.set_param(bt_set_param),.set_val(bt_set_val),
 .cur_tone(2'd0),.cur_bend(6'd0),.cur_vib(2'd0),.cur_delay(1'b0),
 .rec_start(bt_rec_start),.rec_stop(bt_rec_stop),.rec_raddr(bt_rec_raddr),
 .rec_rdata(rec_rdata),.rec_busy(1'b0),.rec_ready(rec_ready),
 .rec_full(1'b0),.rec_bytes(rec_bytes));
wire [10:0] g_raddr; wire [7:0] g_rdata;
song_ram u_song(.clk(clk),.we(song_we),.waddr(song_waddr),.wdata(song_wdata),
 .raddr(g_raddr),.rdata(g_rdata));
reg [23:0] keys=24'd0;
wire g_busy,g_valid,g_done;
wire [23:0] g_targets;
wire [8:0] g_idx,g_total;
wire g_urgent;
wire [8:0] g_hit,g_miss;
reg  g_t16=0;
guide_player u_guide(.clk(clk),.rst(rst),
 .start(bt_gstart),.song_id(bt_gsong),.cnt_in(bt_counts[9*bt_gsong +: 9]),
 .stop(bt_gstop),.t16_tick(g_t16),
 .raddr(g_raddr),.rdata(g_rdata),.keys(keys),
 .busy(g_busy),.target_keys(g_targets),.target_valid(g_valid),.urgent(g_urgent),
 .idx(g_idx),.total(g_total),.done(g_done),
 .hit_cnt(g_hit),.miss_cnt(g_miss));

localparam integer BDIV=434;        // 50MHz/115200
localparam integer HALF=217;
task uart_byte;
 input [7:0] b;
 integer i;
 begin
  bt_rxd=0;repeat(BDIV) @(negedge clk);
  for(i=0;i<8;i=i+1) begin bt_rxd=b[i];repeat(BDIV) @(negedge clk);end
  bt_rxd=1;repeat(BDIV) @(negedge clk);
 end
endtask

function [15:0] crc16;
 input [7:0] b;
 input [15:0] cin;
 integer k;
 reg [15:0] c;
 begin
  c=cin;
  for(k=0;k<8;k=k+1) begin
   if(c[15]^b[7-k]) c=(c<<1)^16'h1021;
   else           c=c<<1;
  end
  crc16=c;
 end
endfunction

reg [7:0] pl[0:39];
task send_frame;
 input [7:0] cmd;
 input integer len;
 input integer corrupt;
 integer i;
 reg [15:0] c;
 begin
  repeat(60000) @(negedge clk);
  uart_byte(8'hA5);
  uart_byte(len[7:0]);
  uart_byte(cmd);
  c=crc16(len[7:0],16'hFFFF);
  c=crc16(cmd,c);
  for(i=0;i<len;i=i+1) begin uart_byte(pl[i]);c=crc16(pl[i],c);end
  if(corrupt) begin uart_byte(c[7:0]^8'h01);uart_byte(c[15:8]);end
  else        begin uart_byte(c[7:0]);      uart_byte(c[15:8]);end
 end
endtask

reg [7:0] rxb[0:15];
integer rxn=0;
reg [7:0] capb; reg capv; reg [3:0] ci; reg [1:0] cst; reg [15:0] ccnt;
always @(posedge clk) begin
 if(rst) begin cst<=0;capv<=0;ccnt<=0;ci<=0;capb<=0;rxn<=0;end
 else begin
  capv<=0;
  case(cst)
   0: if(!bt_txd) begin cst<=1;ccnt<=0;end
   1: if(ccnt>=HALF-1) begin ccnt<=0;ci<=0;cst<=2;end else ccnt<=ccnt+1;
   2: if(ccnt>=BDIV-1) begin
       ccnt<=0;capb<={bt_txd,capb[7:1]};
       if(ci==4'd7) cst<=3; else ci<=ci+1;
      end else ccnt<=ccnt+1;
   3: if(ccnt>=BDIV-1) begin ccnt<=0;capv<=1;cst<=0;end else ccnt<=ccnt+1;
  endcase
  if(capv && rxn<16) begin rxb[rxn]<=capb;rxn<=rxn+1;end
 end
end

task key_press;
 input integer k;
 begin
  keys=24'd0;repeat(20) @(negedge clk);
  keys=24'd1<<k;repeat(40) @(negedge clk);
  keys=24'd0;repeat(40) @(negedge clk);
  // GUIDE 命中后有熄灭间隔，需要补一个 1/16 拍才前进
  gtick;
 end
endtask

// 手动给 GUIDE 一个 1/16 拍脉冲
task gtick; begin g_t16=1; @(negedge clk); g_t16=0; repeat(30) @(negedge clk); end endtask

wire [9:0]  p_wr_idx  = u_bt.wr_idx;
wire [7:0]  p_exp_seq = u_bt.exp_seq;
wire [7:0]  p_result  = u_bt.act_result;

integer i;
initial begin
 repeat(10) @(negedge clk);rst=0;
 repeat(50) @(negedge clk);

 // 上电必须处于离线
 if(link_ok!==1'b0) $fatal(1,"power-on must be OFFLINE");
 $display("  ok power-on is OFFLINE");

 pl[0]=8'd0; pl[1]=8'd4;                       // BEGIN{song=0,count=4}
 send_frame(8'h01,2,0);
 pl[0]=8'd0; pl[1]=8'd16;                      // DATA{seq=0,n=16} = 4 事件 x 4 字节
 pl[2]=8'd32; pl[3]=8'd0;  pl[4]=8'd0;  pl[5]=8'd8;    // key5  -> LO bit5
 pl[6]=8'd128;pl[7]=8'd0;  pl[8]=8'd0;  pl[9]=8'd8;    // key7  -> LO bit7
 pl[10]=8'd0; pl[11]=8'd2; pl[12]=8'd0; pl[13]=8'd8;   // key9  -> MID bit1
 pl[14]=8'd0; pl[15]=8'd8; pl[16]=8'd0; pl[17]=8'd8;   // key11 -> MID bit3
 send_frame(8'h02,18,0);
 pl[0]=8'd0;                                   // END{song=0}
 send_frame(8'h03,1,0);
 repeat(2000) @(negedge clk);
 if(link_ok!==1'b1)     $fatal(1,"link_ok must be 1 after a valid frame");
 if(ready_mask[0]!==1'b1)$fatal(1,"song0 not ready");
 if(rx_total!==9'd4)    $fatal(1,"rx_total=%0d want 4",rx_total);
 if(bt_counts[8:0]!==9'd4) $fatal(1,"song_counts[0]=%0d want 4",bt_counts[8:0]);
 // 曲谱 RAM 逐字节核对（直接读阵列）
 if(u_song.mem[0]!==8'd32)  $fatal(1,"ev0 LO=%0d",u_song.mem[0]);
 if(u_song.mem[1]!==8'd0)   $fatal(1,"ev0 MID=%0d",u_song.mem[1]);
 if(u_song.mem[2]!==8'd0)   $fatal(1,"ev0 HI=%0d",u_song.mem[2]);
 if(u_song.mem[3]!==8'd8)   $fatal(1,"ev0 DUR=%0d",u_song.mem[3]);
 if(u_song.mem[4]!==8'd128) $fatal(1,"ev1 LO=%0d",u_song.mem[4]);
 if(u_song.mem[9]!==8'd2)   $fatal(1,"ev2 MID=%0d",u_song.mem[9]);
 if(u_song.mem[13]!==8'd8)  $fatal(1,"ev3 MID=%0d",u_song.mem[13]);
 $display("  ok download: 4 events stored, ready_mask=%b, link=1",ready_mask);

 pl[0]=8'd0; pl[1]=8'd16;
 for(i=2;i<18;i=i+1) pl[i]=8'hAA;
 send_frame(8'h02,18,1);                       // 故意把 CRC 弄错
 repeat(2000) @(negedge clk);
 if(u_song.mem[0]!==8'd32)  $fatal(1,"corrupt frame overwrote ev0");
 if(ready_mask[0]!==1'b1)   $fatal(1,"corrupt frame destroyed ready bit");
 $display("  ok corrupt CRC frame rejected, song intact");

 repeat(120000) @(negedge clk);
 rxn=0;
 pl[0]=8'd0;
 send_frame(8'h06,0,0);
 repeat(200000) @(negedge clk);
 if(rxn<10) $fatal(1,"STATUS reply too short: %0d bytes",rxn);
 if(rxb[0]!==8'h5A) $fatal(1,"reply SOF=%h",rxb[0]);
 if(rxb[1]!==8'd5)  $fatal(1,"reply LEN=%0d",rxb[1]);
 if(rxb[2]!==8'h82) $fatal(1,"reply CMD=%h",rxb[2]);
 if(rxb[7]!==8'd1)  $fatal(1,"STATUS ready byte=%0d (index 7)",rxb[7]);
 begin : chk_crc
  reg [15:0] c; integer k;
  c=crc16(rxb[1],16'hFFFF);
  for(k=2;k<8;k=k+1) c=crc16(rxb[k],c);
  if(rxb[8]!==c[7:0] || rxb[9]!==c[15:8]) $fatal(1,"STATUS CRC mismatch");
 end
 $display("  ok QUERY -> STATUS frame, header and CRC verified");

 pl[0]=8'd0;
 send_frame(8'h04,1,0);
 repeat(4000) @(negedge clk);
 if(g_busy!==1'b1)   $fatal(1,"guide did not start");
 if(g_valid!==1'b1)  $fatal(1,"target not valid");
 if(g_targets!==24'h000020) $fatal(1,"first target=%06h want key5",g_targets);
 $display("  ok guide started, first target mask = %06h",g_targets);
 key_press(3);
 if(g_targets!==24'h000020) $fatal(1,"wrong key advanced the target to %06h",g_targets);
 if(g_idx!==9'd0)    $fatal(1,"wrong key advanced idx to %0d",g_idx);
 $display("  ok wrong key does NOT advance");
 // 依次按对 4 个键
 key_press(5);
 if(g_targets!==24'h000080) $fatal(1,"after key5 target=%06h want key7",g_targets);
 key_press(7);
 if(g_targets!==24'h000200) $fatal(1,"after key7 target=%06h want key9",g_targets);
 key_press(9);
 if(g_targets!==24'h000800)$fatal(1,"after key9 target=%06h want key11",g_targets);
 key_press(11);
 repeat(500) @(negedge clk);
 if(g_busy!==1'b0)  $fatal(1,"guide should finish after the last note");
 if(g_done!==1'b1)  $fatal(1,"guide done flag missing");
 if(g_valid!==1'b0) $fatal(1,"target should be cleared at the end");
 $display("  ok guide walks 5->7->9->11 and finishes");

 // STOP 也要能停
 send_frame(8'h04,1,0);
 repeat(3000) @(negedge clk);
 if(g_busy!==1'b1) $fatal(1,"guide restart failed");
 pl[0]=8'd0;
 send_frame(8'h05,0,0);
 repeat(2000) @(negedge clk);
 if(g_busy!==1'b0) $fatal(1,"STOP did not stop the guide");
 $display("  ok STOP stops the guide");

 begin : known_crc
  reg [15:0] c; integer j;
  c=16'hffff;
  for(j=49;j<=57;j=j+1) c=crc16(j,c);
  if(c!==16'h29b1) $fatal(1,"CCITT-FALSE known vector failed");
 end
 pl[0]=1;pl[1]=0;send_frame(1,2,0);
 repeat(3000) @(negedge clk);
 if(ready_mask[1] || p_result!=8'd3) $fatal(1,"zero count BEGIN accepted");
 pl[0]=1;pl[1]=1;send_frame(1,2,0);          // BEGIN{song=1,count=1} = 1 事件 = 4 字节
 pl[0]=0;pl[1]=2;pl[2]=7;pl[3]=0;send_frame(2,4,0);
 repeat(3000) @(negedge clk);
 if(p_wr_idx!=10'd0 || p_exp_seq!=8'd0) $fatal(1,"n not multiple of 4 accepted");
 pl[0]=0;pl[1]=4;pl[2]=7;pl[3]=0;pl[4]=0;pl[5]=0;send_frame(2,6,0);
 repeat(3000) @(negedge clk);
 if(p_wr_idx!=10'd0 || p_exp_seq!=8'd0) $fatal(1,"illegal DUR committed");
 // seq 错：必须拒且不推进上下文
 pl[0]=1;pl[1]=4;pl[2]=7;pl[3]=0;pl[4]=0;pl[5]=8;send_frame(2,6,0);
 repeat(3000) @(negedge clk);
 if(p_exp_seq!=8'd0) $fatal(1,"wrong sequence advanced context");
 pl[0]=0;pl[1]=4;pl[2]=7;pl[3]=0;pl[4]=0;pl[5]=8;send_frame(2,6,0);
 repeat(3000) @(negedge clk);
 if(u_song.mem[512]!=7 || u_song.mem[515]!=8) $fatal(1,"correct retry failed");
 if(p_wr_idx!=10'd4) $fatal(1,"wr_idx=%0d want 4",p_wr_idx);
 send_frame(2,6,0);
 repeat(3000) @(negedge clk);
 if(p_wr_idx!=10'd4 || p_exp_seq!=8'd1) $fatal(1,"duplicate DATA committed twice");
 pl[0]=0;send_frame(3,1,0);
 repeat(3000) @(negedge clk);
 if(ready_mask[1]) $fatal(1,"wrong END song accepted");
 pl[0]=1;send_frame(3,1,0);
 repeat(3000) @(negedge clk);
 if(!ready_mask[1]) $fatal(1,"correct END failed");
 @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;
 repeat(3) @(negedge clk);
 if(ready_mask[0] || bt_counts[8:0]!=0) $fatal(1,"soft reset advertised overwritten builtin");

 begin : commit_len
  integer ck;
  for(ck=0;ck<64;ck=ck+1) u_song.mem[1024+ck]=8'hEE;
  rec_ready=1'b1;
  rec_bytes=12'd12;
  pl[0]=2;send_frame(8'h0C,1,0);              // REC_COMMIT{song=2}
  repeat(4000) @(negedge clk);
  if(!ready_mask[2]) $fatal(1,"COMMIT should mark slot 2 ready");
  if(bt_counts[9*2 +: 9]!==9'd3)
    $fatal(1,"COMMIT song_counts=%0d want 3 (12 bytes / 4)",bt_counts[9*2 +: 9]);
  rec_ready=1'b0;
  $display("  ok COMMIT reports event count (not byte/2)");
 end

 $display("PASS review_bt: UART protocol, guide(mask target), CRC known vector, bad n/DUR/count/seq, retry, duplicate, END bounds, COMMIT len");
 $finish;
end
initial begin #200000000;$fatal(1,"bt timeout");end
endmodule
