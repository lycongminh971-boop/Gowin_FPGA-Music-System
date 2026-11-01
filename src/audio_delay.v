module audio_delay #(parameter AW=13)(
 input wire clk,rst,valid,enable,
 input wire signed [15:0] din,
 output reg signed [15:0] dout,
 output reg dout_valid
);
reg [AW-1:0] ptr;
reg filled;
reg signed [15:0] dry,echo;
wire signed [15:0] ram_q;
reg selected;
reg [1:0] state;
wire signed [16:0] feedback=$signed(dry)+($signed(echo)>>>1);
wire signed [16:0] mixed=($signed(dry)>>>1)+($signed(echo)>>>1);
function [15:0] sat;
 input signed [16:0] x;
 begin
  if(x>32767) sat=16'h7fff;
  else if(x< -32768) sat=16'h8000;
  else sat=x[15:0];
 end
endfunction
wire [15:0] write_data=selected?sat(feedback):16'd0;
genvar bank;
generate for(bank=0;bank<8;bank=bank+1) begin:delay_ram
 wire [31:0] data_out;
 SP #(.BIT_WIDTH(2),.READ_MODE(1'b0),.WRITE_MODE(2'b01),.BLK_SEL(3'b000)) memory(
  .DO(data_out),.DI({30'd0,write_data[bank*2+:2]}),
  .BLKSEL(3'b000),.AD({{(13-AW){1'b0}},ptr,1'b0}),
  .WRE(state==1),.CLK(clk),.CE(1'b1),.OCE(1'b1),.RESET(rst));
 assign ram_q[bank*2+:2]=data_out[1:0];
end endgenerate
always @(posedge clk) begin
 if(rst) begin
  ptr<=0;filled<=0;dry<=0;echo<=0;state<=0;dout<=0;dout_valid<=0;selected<=0;
 end else begin
  dout_valid<=0;
  case(state)
   0:if(valid) begin
    dry<=din;selected<=enable;
    echo<=filled?ram_q:16'sd0;state<=1;
   end
   1:begin
    dout<=selected?sat(mixed):dry;
    ptr<=ptr+1'b1;
    if(&ptr) filled<=1;
    dout_valid<=1;state<=0;
   end
   default:state<=0;
  endcase
 end
end
endmodule
