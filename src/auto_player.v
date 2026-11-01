module auto_player (
 input  wire clk,
 input  wire rst,
 input  wire        start,
 input  wire [1:0]  song_id,
 input  wire [8:0]  cnt_in,      // 本首事件总数（来自 bt_link 的 song_counts）
 input  wire        stop,
 input  wire        t16_tick,    // 1/16 音符结束
 input  wire        t16_half,    // 1/16 音符走到一半（断音点）
 output reg  [10:0] raddr,
 input  wire [7:0]  rdata,
 output reg  [23:0] auto_keys,   // 当前发声的键位掩码（直接并进引擎的 key 通路）
 output reg         busy,
 output reg  [8:0]  idx,
 output reg  [8:0]  total,
 output reg         done
);
localparam [3:0] A_IDLE=4'd0,A_ADV=4'd1,A_FK=4'd2,A_FD=4'd3,A_FH=4'd4,
                 A_GB=4'd5,A_GD=4'd6,A_HOLD=4'd7,A_REST=4'd8;
reg [3:0]  gst;
reg [10:0] base;
wire [10:0] ra0 = base + {idx,2'b00};
reg [7:0]  rem16;               // 本事件还剩几个 1/16
reg [7:0]  klo,kmi,khi;         // 三个键位字节的暂存

always @(posedge clk) begin
 if(rst) begin
  gst<=A_IDLE;base<=0;raddr<=0;auto_keys<=0;busy<=0;idx<=0;total<=0;done<=0;
  rem16<=0;klo<=0;kmi<=0;khi<=0;
 end else begin
  if(stop) begin
   gst<=A_IDLE;busy<=1'b0;auto_keys<=24'd0;done<=1'b0;
  end else if(start) begin
   base<={song_id,9'd0};           // 每首 512 字节
   idx<=9'd0;total<=cnt_in;
   busy<=1'b1;done<=1'b0;auto_keys<=24'd0;
   gst<=A_ADV;
  end else if(busy) begin
   case(gst)
    A_ADV: begin
     if(idx>=total) begin
      // 曲终：必须把 keys 清掉，否则最后一个和弦会一直响到下次 start
      busy<=1'b0;done<=1'b1;auto_keys<=24'd0;gst<=A_IDLE;
     end else begin
      raddr<=ra0;                  // A0 = KEYS_LO
      gst<=A_FK;
     end
    end
    A_FK: begin raddr<=ra0+11'd1; gst<=A_FD; end   // 排 A1，rdata 稍后是 A0
    A_FD: begin klo<=rdata; raddr<=ra0+11'd2; gst<=A_FH; end  // rdata = LO
    A_FH: begin kmi<=rdata; raddr<=ra0+11'd3; gst<=A_GB; end  // rdata = MID
    A_GB: begin khi<=rdata; gst<=A_GD; end                    // rdata = HI
    A_GD: begin
     // 这一拍 rdata = DUR；klo/kmi/khi 三个字节都已锁存
     rem16<=(rdata==8'd0)?8'd1:rdata;      // dur==0（未初始化槽位）按 1 处理，否则瞬间跨过
     if({khi,kmi,klo}==24'd0) begin
      auto_keys<=24'd0;                            // 全 0 = 休止：不发声，但按自己的时值等
      gst<=A_REST;
     end else begin
      auto_keys<={khi,kmi,klo};                    // 复音：整个和弦一起送进引擎
      gst<=A_HOLD;
     end
    end
    A_HOLD: begin
     // 断音点：最后一个 1/16 走到一半时把键抬起来
     if(t16_half && rem16<=8'd1) auto_keys<=24'd0;
     if(t16_tick) begin
      if(rem16<=8'd1) begin
       idx<=idx+1'b1;auto_keys<=24'd0;gst<=A_ADV;
      end else rem16<=rem16-8'd1;
     end
    end
    A_REST: begin
     if(t16_tick) begin
      if(rem16<=8'd1) begin idx<=idx+1'b1;gst<=A_ADV; end
      else rem16<=rem16-8'd1;
     end
    end
    default: gst<=A_IDLE;
   endcase
  end
 end
end
endmodule
