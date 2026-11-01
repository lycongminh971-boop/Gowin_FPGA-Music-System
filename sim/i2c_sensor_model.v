`timescale 1ns/1ps
// i2c_sensor_model.v —— I2C 从机行为模型，模拟 MPR121 触摸与 VL53L0X 测距。
// KIND=0 对应 MPR121 寄存器，KIND=1/2 对应 VL53 距离与就绪值。
// 按总线边沿解码 START/STOP，不依赖主机四相位实现；非电容/光学物理模型。
// 注意：FILTER_NS 为触摸值更新周期，0x5e 低 4 位为 0 时触摸量清零。
module i2c_sensor_model #(
 parameter [6:0] ADDRESS=7'h5a,parameter KIND=0,
 parameter integer FILTER_NS=4_000_000
)(inout wire scl,inout wire sda,input wire enable,input wire nack_data,
 input wire [11:0] touch,input wire [15:0] distance,input wire overcurrent);
reg [7:0] mem[0:255];
reg [11:0] sensed=0,snapshot=0;
reg drive=0;
assign sda=drive?1'b0:1'bz;
localparam IDLE=0,ADDRESS_RX=1,ACK_ADDR=2,INDEX_RX=3,ACK_INDEX=4,
 DATA_RX=5,ACK_DATA=6,DATA_TX=7,MASTER_ACK=8,NEXT_BYTE=9;
integer state=IDLE,bitn=0,ack_phase=0;
reg [7:0] shift=0,ptr=0,tx=0;
reg reading=0,accept=0,master_ack=0;
integer j;
task defaults;
 begin
  for(j=0;j<256;j=j+1) mem[j]=0;
  mem[8'h5c]=8'h10;mem[8'h5d]=8'h24;
 end
endtask
initial defaults;
always #(FILTER_NS) begin
 if(KIND==0 && mem[8'h5e][3:0]!=0) sensed=touch;
 else sensed=0;
end
function [7:0] read_reg;
 input [7:0] a;
 begin
  read_reg=mem[a];
  if(KIND==0) begin
   if(a==0) read_reg=snapshot[7:0];
   if(a==1) read_reg={overcurrent,3'b000,snapshot[11:8]};
  end else case(a)
   8'hc0:read_reg=8'hee;
   // KIND=2 时对 0x13/0x83/0x92 给出就绪值，不代表物理校准已验证。
   8'h13:read_reg=(KIND==2)?8'h07:mem[a];
   8'h83:read_reg=(KIND==2)?8'h01:mem[a];
   8'h92:read_reg=(KIND==2)?8'h85:mem[a];
   8'h14:read_reg=8'h59;
   8'h1e:read_reg=distance[15:8];
   8'h1f:read_reg=distance[7:0];
   default:read_reg=mem[a];
  endcase
 end
endfunction
// START/STOP 由总线边沿判定，不用固定延时猜读写方向。
always @(negedge sda) if(scl===1'b1) begin
 state=ADDRESS_RX;bitn=0;shift=0;ack_phase=0;
end
always @(posedge sda) if(scl===1'b1) begin state=IDLE;drive=0;end
always @(posedge scl) begin
 case(state)
 ADDRESS_RX,INDEX_RX,DATA_RX:begin
  shift={shift[6:0],sda};
  if(bitn==7) begin
   bitn=0;ack_phase=0;
   case(state)
    ADDRESS_RX:begin
     accept=enable && shift[7:1]==ADDRESS;reading=shift[0];state=ACK_ADDR;
     if(reading) snapshot=sensed;
    end
    INDEX_RX:begin ptr=shift;accept=enable;state=ACK_INDEX;end
    DATA_RX:begin
     accept=enable && !nack_data;
     if(accept) begin
      if(KIND==0 && ptr==8'h80 && shift==8'h63) defaults;
      else mem[ptr]=shift;
     end
     state=ACK_DATA;
    end
   endcase
  end else bitn=bitn+1;
 end
 ACK_ADDR,ACK_INDEX,ACK_DATA:if(ack_phase==1) ack_phase=2;
 DATA_TX:begin
  if(bitn==7) begin state=MASTER_ACK;ack_phase=0;end
  else bitn=bitn+1;
 end
 MASTER_ACK:if(ack_phase==1) begin master_ack=(sda===1'b0);state=NEXT_BYTE;end
 default:begin end
 endcase
end
always @(negedge scl) begin
 case(state)
 ACK_ADDR,ACK_INDEX,ACK_DATA:begin
  if(ack_phase==0) begin drive=accept;ack_phase=1;end
  else if(ack_phase==2) begin
   drive=0;bitn=0;shift=0;
   if(!accept) state=IDLE;
   else if(state==ACK_ADDR) begin
    if(reading) begin tx=read_reg(ptr);drive=~tx[7];state=DATA_TX;end
    else state=INDEX_RX;
   end else if(state==ACK_INDEX) state=DATA_RX;
   else begin ptr=ptr+1'b1;state=DATA_RX;end
  end
 end
 DATA_TX:drive=~tx[7-bitn];
 MASTER_ACK:begin drive=0;ack_phase=1;end
 NEXT_BYTE:begin
  drive=0;
  if(master_ack) begin
   ptr=ptr+1'b1;tx=read_reg(ptr);bitn=0;drive=~tx[7];state=DATA_TX;
  end else state=IDLE;
 end
 default:begin end
 endcase
end
endmodule
