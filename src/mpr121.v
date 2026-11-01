module mpr121 #(
 parameter integer CLK_HZ=50_000_000, SCL_HZ=100_000,
 parameter [6:0] DEV_ADDR=7'h5a,
 parameter [7:0] TOUCH_TH=12, RELEASE_TH=6,
 parameter integer POLL_CNT=25_000, BOOT_CNT=50_000,
 parameter integer SETTLE_CNT=1_600_000, RETRY_CNT=1_000_000
)(input wire clk,input wire rst,inout wire scl,inout wire sda,
 output reg [11:0] key,output reg frame_stb,output reg ready,output reg fault);
localparam WAIT_BOOT=0,RESET_DEV=1,WAIT_RESET=2,CHECK_RESET=3,CONFIG=4,
 VERIFY_C=5,VERIFY_D=6,VERIFY_E=7,SETTLE=8,POLL_WAIT=9,READ_KEYS=10,RETRY=11;
reg [3:0] state;
reg [31:0] timer;
reg [5:0] cfg;
reg pending,go,rd;
reg [7:0] idx,data,lo,hi;
reg [4:0] nb;
reg [2:0] count;
wire [7:0] rx;
wire rvld,busy,done,ackerr;
// 批注：先停机配置基线/阈值，最后ECR=8C启用12路与快速初始基线。
always @* begin
 rd=0;idx=0;data=0;nb=0;
 case(state)
 RESET_DEV:begin idx=8'h80;data=8'h63;end
 CHECK_RESET:begin rd=1;idx=8'h5d;end
 CONFIG:begin
  if(cfg>=12 && cfg<36) begin
   idx=8'h41+({2'b00,cfg}-8'd12);data=cfg[0]?RELEASE_TH:TOUCH_TH;
  end else case(cfg)
   0:begin idx=8'h5e;data=0;end
   1:begin idx=8'h2b;data=1;end
   2:begin idx=8'h2c;data=1;end
   3:begin idx=8'h2d;data=0;end
   4:begin idx=8'h2e;data=0;end
   5:begin idx=8'h2f;data=1;end
   6:begin idx=8'h30;data=1;end
   7:begin idx=8'h31;data=8'hff;end
   8:begin idx=8'h32;data=2;end
   9:begin idx=8'h33;data=0;end
   10:begin idx=8'h34;data=0;end
   11:begin idx=8'h35;data=0;end
   36:begin idx=8'h5b;data=0;end
   37:begin idx=8'h5c;data=8'h10;end
   38:begin idx=8'h5d;data=8'h20;end
   39:begin idx=8'h5e;data=8'h8c;end
   default:begin idx=8'h5e;data=0;end
  endcase
 end
 VERIFY_C:begin rd=1;idx=8'h5c;end
 VERIFY_D:begin rd=1;idx=8'h5d;end
 VERIFY_E:begin rd=1;idx=8'h5e;end
 READ_KEYS:begin rd=1;idx=0;nb=1;end
 default:begin end
 endcase
end
i2c_master #(.CLK_HZ(CLK_HZ),.SCL_HZ(SCL_HZ)) bus(
 .clk(clk),.rst(rst),.go(go),.rd(rd),.dev(DEV_ADDR),.idx(idx),.wdata(data),
 .nbytes(nb),.rdata(rx),.rvld(rvld),.busy(busy),.done(done),.ackerr(ackerr),
 .scl(scl),.sda(sda));
always @(posedge clk) begin
 if(rst) begin
  state<=WAIT_BOOT;timer<=0;cfg<=0;pending<=0;go<=0;
  lo<=0;hi<=0;count<=0;key<=0;frame_stb<=0;ready<=0;fault<=0;
 end else begin
  go<=0;frame_stb<=0;
  if(!pending) begin
   case(state)
    WAIT_BOOT,WAIT_RESET,SETTLE,POLL_WAIT,RETRY:begin
     if((state==WAIT_BOOT && timer>=BOOT_CNT-1) ||
        (state==WAIT_RESET && timer>=BOOT_CNT-1) ||
        (state==SETTLE && timer>=SETTLE_CNT-1) ||
        (state==POLL_WAIT && timer>=POLL_CNT-1) ||
        (state==RETRY && timer>=RETRY_CNT-1)) begin
      timer<=0;
      case(state)
       WAIT_BOOT,RETRY:state<=RESET_DEV;
       WAIT_RESET:state<=CHECK_RESET;
       SETTLE:begin state<=READ_KEYS;ready<=1;fault<=0;end
       default:state<=READ_KEYS;
      endcase
     end else timer<=timer+1'b1;
    end
    default:if(!busy) begin go<=1;pending<=1;count<=0;lo<=0;hi<=0;end
   endcase
  end else begin
   if(rvld) begin
    if(count==0) lo<=rx;else if(count==1) hi<=rx;
    count<=count+1'b1;
   end
   if(done) begin
    pending<=0;timer<=0;
    if(ackerr || (rd && count!=(state==READ_KEYS?2:1)) ||
       (state==CHECK_RESET && lo!=8'h24) ||
       (state==VERIFY_C && lo!=8'h10) || (state==VERIFY_D && lo!=8'h20) ||
       (state==VERIFY_E && lo!=8'h8c) || (state==READ_KEYS && hi[7])) begin
     state<=RETRY;key<=0;ready<=0;fault<=1;cfg<=0;
    end else case(state)
     RESET_DEV:state<=WAIT_RESET;
     CHECK_RESET:begin state<=CONFIG;cfg<=0;end
     CONFIG:if(cfg==39) state<=VERIFY_C;else cfg<=cfg+1'b1;
     VERIFY_C:state<=VERIFY_D;
     VERIFY_D:state<=VERIFY_E;
     VERIFY_E:state<=SETTLE;
     READ_KEYS:begin
      // 批注：触摸状态0x00是低字节，0x01是高4位，不能套用VL53距离字节序。
      key<={hi[3:0],lo};frame_stb<=1;state<=POLL_WAIT;
     end
     default:state<=RETRY;
    endcase
   end
  end
 end
end
endmodule
