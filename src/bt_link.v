module bt_link #(
 parameter integer CLK_HZ=50_000_000
)(
 input  wire clk,
 input  wire rst,
 input  wire [7:0] rx_data,
 input  wire       rx_valid,
 output reg  [7:0] tx_data,
 output reg        tx_send,
 input  wire       tx_busy,
 output reg        song_we,
 output reg  [10:0] song_waddr,
 output reg  [7:0]  song_wdata,
 output reg  [3:0] ready_mask,
 output reg        link_ok,
 output reg  [8:0] rx_done,
 output reg  [8:0] rx_total,
 output reg  [2:0] state,        // 0=IDLE 1=RXING 2=READY 3=ERROR
 output reg        guide_start,
 output reg  [1:0] guide_song,
 output reg        guide_stop,
 output reg        auto_start,
 output reg  [1:0] auto_song,
 output reg        set_vld,
 output reg  [2:0] set_param,      // 0=音色 1=变调 2=颤音 3=延时 4=节奏
 output reg  [2:0] tempo_sel,
 output reg        tempo_vld,      // 1 拍脉冲：档位刚被蓝牙改过
 // 2026-10-29 新增：GUIDE 严格节奏模式开关（SET param=5, value 0/1）
 output reg        strict_rhythm,
 input  wire [2:0] cur_tempo,
 output reg  [7:0] set_val,
 input  wire [1:0] cur_tone,
 input  wire [5:0] cur_bend,
 input  wire [1:0] cur_vib,
 input  wire       cur_delay,
 // 录音控制
 output reg        rec_start,      // 1 鎷嶈剦鍐?
 output reg        rec_stop,       // 1 鎷嶈剦鍐?
 output reg  [10:0] rec_raddr,
 input  wire [7:0]  rec_rdata,
 input  wire        rec_busy,
 input  wire        rec_ready,
 input  wire        rec_full,
 input  wire [11:0] rec_bytes,
 output reg  [35:0] song_counts
);
localparam [7:0] SOF_IN=8'hA5,SOF_OUT=8'h5A;
localparam [7:0] C_BEGIN=8'h01,C_DATA=8'h02,C_END=8'h03,C_PLAY=8'h04,C_STOP=8'h05,C_QUERY=8'h06;
localparam [7:0] C_MODE=8'h07,C_SET=8'h08,C_PARA=8'h09;
       localparam [7:0] C_TEMPO=8'h0F;
localparam [7:0] C_REC_START=8'h0A,C_REC_STOP=8'h0B,C_REC_COMMIT=8'h0C,
                 C_REC_READ=8'h0D,C_REC_INFO=8'h0E;
localparam [7:0] R_ACK=8'h81,R_STATUS=8'h82,R_PARAM=8'h83,R_RECINFO=8'h84,R_DATA=8'h85;
localparam [7:0] R_TEMPO=8'h86;   // 2026-10-28：TEMPO 回帧 {档位, BPM}
localparam [7:0] C_CLEAR=8'h10;
localparam [2:0] P_HUNT=3'd0,P_LEN=3'd1,P_CMD=3'd2,P_PAY=3'd3,P_CL0=3'd4,P_CL1=3'd5;
localparam [1:0] T_IDLE=2'd0,T_CRC=2'd1,T_SEND=2'd2;
localparam [2:0] A_NONE=3'd0,A_ACK=3'd1,A_DATA=3'd2,A_VALIDATE=3'd3,
                 A_COMMIT=3'd4,A_RREAD=3'd5,A_RREAD_W=3'd6;
localparam [8:0] BUILTIN_NOTES = 9'd62;
localparam [3:0] BUILTIN_READY = 4'b0001;
reg [31:0] frame_idle;
reg [15:0] last_data_crc;

// 收帧
reg  [2:0] pst;
reg  [7:0] plen,pcmd,pcnt;
reg  [7:0] pbuf[0:39];
reg  [7:0] crc_lo_r;
reg  [15:0] rxcrc;
reg  [7:0]  rc_byte,rc_in;
reg  [2:0]  rc_i;
reg         rc_run,rc_start,rc_clr;
reg  [15:0] txcrc;
reg  [7:0]  tc_byte,tc_in;
reg  [2:0]  tc_i;
reg         tc_run,tc_start,tc_clr;
// 回帧
reg  [7:0] txbuf[0:39];
reg  [5:0] txl,ti,si;
reg  [1:0] txst;
reg        rep_req;
reg  [2:0] rep_kind;
reg  [1:0]  song_id;
reg  [9:0]  wr_idx;
reg  [8:0]  song_cnt;
wire [10:0] expected_bytes={song_cnt,2'b00};
reg  [7:0]  exp_seq;
reg  [10:0] wr_base;
wire [8:0] bend_off = 9'd12 + {1'b0,{{2{cur_bend[5]}},cur_bend}};
//     0鈫?60  1鈫?80  2鈫?100  3鈫?120  4鈫?160  5鈫?200
wire [7:0] tempo_bpm =
 (cur_tempo==3'd0)?8'd60  :
 (cur_tempo==3'd1)?8'd80  :
 (cur_tempo==3'd2)?8'd100 :
 (cur_tempo==3'd3)?8'd120 :
 (cur_tempo==3'd4)?8'd160 : 8'd200;
// 提交动作
reg  [2:0] ast;
reg  [7:0] act_i,act_n,act_cmd,act_result;
// ---- 2026-10-26 录音相关 ----
//     鎷?2  璇? rec_rdata 鍐欒繘 song_ram
reg  [11:0] cm_total,cm_i;
reg  [1:0]  cm_ph;
reg  [10:0] cm_base;
reg  [1:0]  cm_song;
reg  [11:0] rr_addr,rr_i,rr_n;
reg  [1:0]  rr_ph;
reg  [7:0]  rd_buf[0:15];
integer kk;
// 心跳
reg  [27:0] hb_cnt;
reg         link_seen;   // 收到过合法帧才算连上，否则上电就显示 LINKED
integer bi;

reg builtin_dirty=1'b0;
always @(posedge clk) if(song_we && song_waddr<11'd512) builtin_dirty<=1'b1;
always @(posedge clk) begin
 if(rst) begin
  pst<=P_HUNT;plen<=0;pcmd<=0;pcnt<=0;crc_lo_r<=0;
  rxcrc<=16'hFFFF;rc_byte<=0;rc_i<=0;rc_run<=0;rc_start<=0;rc_clr<=0;rc_in<=0;
  tc_start<=0;tc_in<=0;tc_clr<=0;
  txl<=0;ti<=0;si<=0;txst<=T_IDLE;rep_req<=0;rep_kind<=0;
  song_id<=0;wr_idx<=0;song_cnt<=0;exp_seq<=0;wr_base<=0;
  ast<=A_NONE;act_i<=0;act_n<=0;act_cmd<=0;act_result<=0;
  cm_total<=0;cm_i<=0;cm_ph<=0;cm_base<=0;cm_song<=0;
  rr_addr<=0;rr_i<=0;rr_ph<=0;rr_n<=0;
  song_we<=0;song_waddr<=0;song_wdata<=0;
  ready_mask<=builtin_dirty ? 4'd0 : BUILTIN_READY;link_ok<=0;rx_done<=0;rx_total<=0;state<=0;
  guide_start<=0;guide_song<=0;guide_stop<=0;song_counts<=builtin_dirty ? 36'd0 : {27'd0,BUILTIN_NOTES};
  auto_start<=0;auto_song<=0;
  set_vld<=0;set_param<=0;set_val<=0;
  tempo_sel<=3'd3;tempo_vld<=0;strict_rhythm<=1'b0;
  rec_start<=0;rec_stop<=0;rec_raddr<=0;
  tx_data<=0;tx_send<=0;hb_cnt<=0;link_seen<=1'b0;frame_idle<=0;last_data_crc<=0;
  for(bi=0;bi<40;bi=bi+1) txbuf[bi]<=8'd0;
  for(bi=0;bi<16;bi=bi+1) rd_buf[bi]<=8'd0;
  for(bi=0;bi<40;bi=bi+1) pbuf[bi]<=8'd0;
 end else begin
  rc_start<=1'b0;rc_clr<=1'b0;tc_start<=1'b0;tc_clr<=1'b0;
  song_we<=1'b0;guide_start<=1'b0;guide_stop<=1'b0;tx_send<=1'b0;
  auto_start<=1'b0;set_vld<=1'b0;rec_start<=1'b0;rec_stop<=1'b0;tempo_vld<=1'b0;

  // ============ 收帧 CRC ============
  if(rc_clr) rxcrc<=16'hFFFF;
  else if(!rc_run) begin
   if(rc_start) begin rc_byte<=rc_in;rc_run<=1'b1;rc_i<=3'd0;end
  end else begin
   rxcrc<={rxcrc[14:0],1'b0}^((rc_byte[7]^rxcrc[15])?16'h1021:16'h0000);
   rc_byte<={rc_byte[6:0],1'b0};
   if(rc_i==3'd7) rc_run<=1'b0;
   else rc_i<=rc_i+1'b1;
  end

  if(pst==P_HUNT || rx_valid) frame_idle<=0;
  else if(frame_idle>=CLK_HZ-1) begin pst<=P_HUNT;frame_idle<=0;rc_run<=0;end
  else frame_idle<=frame_idle+1'b1;
  if(rx_valid) begin
   case(pst)
    P_HUNT: if(rx_data==SOF_IN && ast==A_NONE && txst==T_IDLE && !rep_req && !tx_busy && !tx_send) begin pst<=P_LEN;rc_clr<=1'b1;end
    P_LEN:  begin
     if(rx_data>34) begin pst<=P_HUNT;state<=3'd3;end
     else begin plen<=rx_data;pcnt<=8'd0;rc_in<=rx_data;rc_start<=1'b1;pst<=P_CMD;end
    end
    P_CMD:  begin
     pcmd<=rx_data;pcnt<=8'd0;rc_in<=rx_data;rc_start<=1'b1;
     pst<=(plen==8'd0)?P_CL0:P_PAY;
    end
    P_PAY:  begin
     pbuf[pcnt]<=rx_data;rc_in<=rx_data;rc_start<=1'b1;
     if(pcnt+1'b1>=plen) pst<=P_CL0;
     else pcnt<=pcnt+1'b1;
    end
    P_CL0:  begin crc_lo_r<=rx_data;pst<=P_CL1;end
    P_CL1:  begin
     pst<=P_HUNT;
     act_cmd<=pcmd;act_i<=8'd0;
     if(!((rx_data==rxcrc[15:8])&&(crc_lo_r==rxcrc[7:0]))) begin
      act_result<=8'd1;ast<=A_ACK;                       // CRC 错，不动曲谱
     end else begin
      hb_cnt<=28'd0;link_seen<=1'b1;
      act_result<=8'd0;
      case(pcmd)
       C_BEGIN: begin
        if(plen!=2 || pbuf[0]>3 || pbuf[1]==0 || pbuf[1]>127)
         begin act_result<=3;ast<=A_ACK;end
        else begin
        song_id<=pbuf[0][1:0];
        wr_base<={pbuf[0][1:0],9'd0};                    // 每首 512 字节
        song_cnt<={1'b0,pbuf[1]};
        wr_idx<=10'd0;exp_seq<=8'd0;
        ready_mask[pbuf[0][1:0]]<=1'b0;
        rx_total<={1'b0,pbuf[1]};rx_done<=9'd0;
        song_counts[9*pbuf[0][1:0] +: 9]<={1'b0,pbuf[1]};
        state<=3'd1;ast<=A_ACK;guide_stop<=1;last_data_crc<=0;
        end
       end
       C_DATA: begin
        act_n<=pbuf[1];
        if(plen<4 || pbuf[1]<4 || pbuf[1]>32 || (|pbuf[1][1:0]) || plen!=pbuf[1]+2)
         begin act_result<=3;ast<=A_ACK;end
        else if(wr_idx!=0 && pbuf[0]==(exp_seq-8'd1) && rxcrc==last_data_crc)
         ast<=A_ACK;
        else if(pbuf[0]!=exp_seq) begin act_result<=2;ast<=A_ACK;end
        else if(state!=1 || song_cnt==0 ||
                ({1'b0,wr_idx}+{3'd0,pbuf[1]})>expected_bytes)
         begin act_result<=3;ast<=A_ACK;end
        else ast<=A_VALIDATE;
       end
       C_END: begin
        if(plen==1 && pbuf[0]=={6'd0,song_id} && song_cnt!=0 && wr_idx==expected_bytes)
         begin ready_mask[song_id]<=1'b1;state<=3'd2;end
        else act_result<=8'd3;
        ast<=A_ACK;
       end
       C_PLAY: begin
        guide_song<=pbuf[0][1:0];
        if(plen==1 && pbuf[0]<4 && ready_mask[pbuf[0][1:0]]) guide_start<=1'b1;
        else act_result<=8'd3;
        ast<=A_ACK;
       end
       C_STOP:  begin if(plen==0) guide_stop<=1'b1;else act_result<=3;ast<=A_ACK;end
       C_QUERY: begin
        if(plen==0) begin rep_kind<=3'd1;rep_req<=1'b1;ast<=A_NONE;end
        else begin act_result<=3;ast<=A_ACK;end
       end
       C_MODE: begin
        if(plen!=2 || pbuf[0]>2 || pbuf[1]>3) begin act_result<=3;ast<=A_ACK;end
        else if(pbuf[0]==8'd0) begin guide_stop<=1'b1;ast<=A_ACK;end
        else if(!ready_mask[pbuf[1][1:0]]) begin act_result<=3;ast<=A_ACK;end
        else if(pbuf[0]==8'd1) begin
         guide_song<=pbuf[1][1:0];guide_start<=1'b1;ast<=A_ACK;
        end else begin
         auto_song<=pbuf[1][1:0];auto_start<=1'b1;ast<=A_ACK;
        end
       end
       // 0x08 SET {param, value}
       //   param 0=音色(0..3) 1=变调(0..24 表示 -12..+12) 2=颤音(0..3) 3=延时(0..1)
       //
       //     beat_gen 本来就是 6 档查表（0..5），只是没人接出来；
       C_SET: begin
        if(plen!=2 || pbuf[0]>5) begin act_result<=3;ast<=A_ACK;end
        else if((pbuf[0]==8'd0 && pbuf[1]>3)  ||
                (pbuf[0]==8'd1 && pbuf[1]>24) ||
                (pbuf[0]==8'd2 && pbuf[1]>3)  ||
                (pbuf[0]==8'd3 && pbuf[1]>1)  ||
                (pbuf[0]==8'd4 && pbuf[1]>5)  ||
                (pbuf[0]==8'd5 && pbuf[1]>1)) begin act_result<=3;ast<=A_ACK;end
        else begin
         // param=5（严格节奏）直接在本模块生效，不进 star.v 的参数寄存器
         if(pbuf[0]==8'd5) strict_rhythm<=pbuf[1][0];
         set_param<=pbuf[0][2:0];set_val<=pbuf[1];set_vld<=1'b1;ast<=A_ACK;
        end
       end
       // 0x09 PARA：查当前生效参数
       C_PARA: begin
        if(plen==0) begin rep_kind<=3'd2;rep_req<=1'b1;ast<=A_NONE;end
        else begin act_result<=3;ast<=A_ACK;end
       end
       // 0x0F TEMPO：{value} 设置节奏档位；空载荷 = 查询当前档位
       C_TEMPO: begin
        if(plen==0) begin
         // 查询：回 {档位, BPM}
         rep_kind<=3'd5;rep_req<=1'b1;ast<=A_NONE;
        end else if(plen==1 && pbuf[0]<=5) begin
         tempo_sel<=pbuf[0][2:0];
         tempo_vld<=1'b1;
         act_result<=8'd0;
         ast<=A_ACK;
        end else begin act_result<=3;ast<=A_ACK;end
       end
       C_CLEAR: begin
        if(plen==0) begin
         ready_mask<=4'd0;
         song_counts<=36'd0;
         guide_stop<=1'b1;
         act_result<=8'd0;
         ast<=A_ACK;
        end else if(plen==1 && pbuf[0]<=3) begin
         ready_mask[pbuf[0][1:0]]<=1'b0;
         song_counts[9*pbuf[0][1:0] +: 9]<=9'd0;
         if(pbuf[0][1:0]==song_id) guide_stop<=1'b1;
         act_result<=8'd0;
         ast<=A_ACK;
        end else begin act_result<=3;ast<=A_ACK;end
       end
       // 0x0A REC_START：开始录音，顺带停掉 GUIDE/AUTO
       C_REC_START: begin
        if(plen!=0 || rec_busy) begin act_result<=3;ast<=A_ACK;end
        else begin rec_start<=1'b1;guide_stop<=1'b1;ast<=A_ACK;end
       end
       C_REC_STOP: begin
        if(plen!=0 || !rec_busy) begin act_result<=3;ast<=A_ACK;end
        else begin rec_stop<=1'b1;ast<=A_ACK;end
       end
       C_REC_COMMIT: begin
        if(plen!=1 || pbuf[0]>3) begin act_result<=3;ast<=A_ACK;end
        else if(!rec_ready || rec_bytes==12'd0) begin act_result<=3;ast<=A_ACK;end
        else begin
         cm_song<=pbuf[0][1:0];
         cm_base<={pbuf[0][1:0],9'd0};      // 每槽 512 字节
         // 2026-10-29 二次审查：上限从 512 收到 **508 字节 = 127 事件**。
         //   为什么是 508 而不是 512：BEGIN 命令的 count 上限是 **127**
         //   （pbuf[1]>127 即拒），而 512/4 = **128** —— COMMIT 能写出
         //   128 个事件的曲谱，却没有任何合法途径用 BEGIN 重新下传它。
         //   结果就是「录音存进去能播，但同步/回读时对不上」，属于隐性不一致。
         //   收到 508 让两条路径的曲长口径统一：最多 127 事件。
         cm_total<=(rec_bytes>12'd508) ? 12'd508 : rec_bytes;
         cm_i<=12'd0;cm_ph<=2'd0;
         ready_mask[pbuf[0][1:0]]<=1'b0;
         ast<=A_COMMIT;
        end
       end
       C_REC_READ: begin
        if(plen!=3 || pbuf[2]==8'd0 || pbuf[2]>16) begin act_result<=3;ast<=A_ACK;end
        else if({1'b0,pbuf[1][2:0],pbuf[0]}+{4'd0,pbuf[2]} > 12'd2048)
         begin act_result<=3;ast<=A_ACK;end
        else begin
         rr_addr<={pbuf[1][2:0],pbuf[0]};
         rr_n<={8'd0,pbuf[2]};
         rr_i<=12'd0;rr_ph<=2'd0;
         ast<=A_RREAD;
        end
       end
       C_REC_INFO: begin
        if(plen==0) begin rep_kind<=3'd3;rep_req<=1'b1;ast<=A_NONE;end
        else begin act_result<=3;ast<=A_ACK;end
       end
       default: begin act_result<=4;ast<=A_ACK;end
      endcase
     end
    end
    default: pst<=P_HUNT;
   endcase
  end

  // ============ 提交动作 ============
  case(ast)
   A_VALIDATE: begin
    if(act_i<act_n) begin
     if(act_i[1:0]==2'd3 && (pbuf[2+act_i]==0 || pbuf[2+act_i]>127))
      begin act_result<=3;ast<=A_ACK;end
     else act_i<=act_i+1'b1;
    end else begin act_i<=0;ast<=A_DATA;end
   end
   A_DATA: begin
    if(act_i<act_n) begin
     if(wr_idx<10'd512) begin
      song_we<=1'b1;
      song_waddr<=wr_base+{1'b0,wr_idx};
      song_wdata<=pbuf[2+act_i];
      wr_idx<=wr_idx+1'b1;
     end
     act_i<=act_i+1'b1;
    end else begin
     rx_done<=wr_idx[9:2];
     act_result<=8'd0;ast<=A_ACK;exp_seq<=exp_seq+1'b1;last_data_crc<=rxcrc;
    end
   end
   A_ACK: begin rep_kind<=3'd0;rep_req<=1'b1;ast<=A_NONE;end
   A_COMMIT: begin
    case(cm_ph)
     2'd0: begin rec_raddr<=cm_i[10:0];cm_ph<=2'd1;end
     2'd1: begin cm_ph<=2'd2;end                  // rdata 在拍1末才有效
     default: begin
      song_we<=1'b1;
      song_waddr<=cm_base+cm_i[10:0];
      song_wdata<=rec_rdata;
      cm_i<=cm_i+12'd1;
      cm_ph<=2'd0;
      if(cm_i+12'd1>=cm_total) begin
       ready_mask[cm_song]<=1'b1;
       song_counts[9*cm_song +: 9]<={1'b0,cm_total[10:2]};
       state<=3'd2;
       ast<=A_ACK;
      end
     end
    endcase
   end
   A_RREAD: begin
    case(rr_ph)
     2'd0: begin rec_raddr<=rr_addr[10:0]+rr_i[10:0];rr_ph<=2'd1;end
     2'd1: begin rr_ph<=2'd2;end
     default: begin
      rd_buf[rr_i[3:0]]<=rec_rdata;
      rr_i<=rr_i+12'd1;
      rr_ph<=2'd0;
      if(rr_i+12'd1>=rr_n) ast<=A_RREAD_W;
     end
    endcase
   end
   A_RREAD_W: begin
    if(rr_ph==2'd0) begin
     txbuf[0]<=SOF_OUT;
     txbuf[1]<=8'd3+rr_n[7:0];                    // LEN = addr(2)+n(1)+data
     txbuf[2]<=R_DATA;
     txbuf[3]<=rr_addr[7:0];
     txbuf[4]<={5'd0,rr_addr[10:8]};
     txbuf[5]<=rr_n[7:0];
     for(kk=0;kk<16;kk=kk+1) if(kk<rr_n) txbuf[6+kk]<=rd_buf[kk];
     txl<=6'd8+rr_n[5:0];                         // 总长 = 8 + n
     rr_ph<=2'd1;
    end else begin
     tc_clr<=1'b1;ti<=6'd1;txst<=T_CRC;
     rr_ph<=2'd0;
     ast<=A_NONE;
    end
   end
   default: ;
  endcase

  // ============ 回帧 ============
  if(rep_req) begin
   rep_req<=1'b0;
   case(rep_kind)
    3'd0: begin
     txbuf[0]<=SOF_OUT;txbuf[1]<=8'd2;txbuf[2]<=R_ACK;
     txbuf[3]<=act_cmd;txbuf[4]<=act_result;
     txl<=6'd7;
    end
    3'd2: begin
     txbuf[0]<=SOF_OUT;txbuf[1]<=8'd4;txbuf[2]<=R_PARAM;
     txbuf[3]<={6'd0,cur_tone};
     txbuf[4]<=bend_off[7:0];
     txbuf[5]<={6'd0,cur_vib};
     txbuf[6]<={7'd0,cur_delay};
     txl<=6'd9;
    end
    3'd3: begin
     // RECINFO：{status, bytes_lo, bytes_hi}
     txbuf[0]<=SOF_OUT;txbuf[1]<=8'd3;txbuf[2]<=R_RECINFO;
     txbuf[3]<={5'd0,rec_full,rec_ready,rec_busy};
     txbuf[4]<=rec_bytes[7:0];
     txbuf[5]<=rec_bytes[11:8];
     txl<=6'd8;
    end
    3'd5: begin
     // 2026-10-28 新增 TEMPO 回帧：{档位, BPM}
     txbuf[0]<=SOF_OUT;txbuf[1]<=8'd2;txbuf[2]<=R_TEMPO;
     txbuf[3]<={5'd0,cur_tempo};
     txbuf[4]<=tempo_bpm;
     txl<=6'd7;
    end
    default: begin
     txbuf[0]<=SOF_OUT;txbuf[1]<=8'd5;txbuf[2]<=R_STATUS;
     txbuf[3]<={5'd0,state};txbuf[4]<={6'd0,song_id};
     txbuf[5]<=rx_done[7:0];txbuf[6]<={7'd0,rx_done[8]};
     txbuf[7]<={4'd0,ready_mask};
     txl<=6'd10;
    end
   endcase
   tc_clr<=1'b1;              // 清零动作交给 CRC 引擎块，本块不直接写 txcrc
   ti<=6'd1;
   txst<=T_CRC;
  end
  if(txst==T_CRC) begin
   if(!tc_run && !tc_start) begin
    if(ti<=txl-4'd3) begin
     tc_in<=txbuf[ti];tc_start<=1'b1;ti<=ti+1'b1;
    end else begin
     txbuf[txl-4'd2]<=txcrc[7:0];
     txbuf[txl-4'd1]<=txcrc[15:8];
     si<=6'd0;txst<=T_SEND;
    end
   end
  end else if(txst==T_SEND) begin
   if(!tx_busy && !tx_send) begin
    tx_data<=txbuf[si];
    tx_send<=1'b1;
    if(si==txl-4'd1) txst<=T_IDLE;
    else si<=si+1'b1;
   end
  end

  // ============ 心跳 ============
  if(!(rx_valid && pst==P_CL1 && rx_data==rxcrc[15:8] && crc_lo_r==rxcrc[7:0])) begin
   if(hb_cnt>=CLK_HZ*5-1) link_seen<=1'b0;
   else hb_cnt<=hb_cnt+28'd1;
  end
  link_ok<=link_seen;
 end
end

always @(posedge clk) begin
 if(rst) begin tc_run<=1'b0;tc_i<=3'd0;txcrc<=16'hFFFF;tc_byte<=8'd0;end
 else if(tc_clr) begin tc_run<=1'b0;tc_i<=3'd0;txcrc<=16'hFFFF;end
 else begin
  if(!tc_run) begin
   if(tc_start) begin tc_byte<=tc_in;tc_run<=1'b1;tc_i<=3'd0;end
  end else begin
   txcrc<={txcrc[14:0],1'b0}^((tc_byte[7]^txcrc[15])?16'h1021:16'h0000);
   tc_byte<={tc_byte[6:0],1'b0};
   if(tc_i==3'd7) tc_run<=1'b0;
   else tc_i<=tc_i+1'b1;
  end
 end
end
endmodule
