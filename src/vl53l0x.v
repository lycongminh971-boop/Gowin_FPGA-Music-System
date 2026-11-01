module vl53l0x #(
 parameter integer CLK_HZ=50000000,SCL_HZ=100000,
 parameter [6:0] DEV_ADDR=7'h29,
 parameter integer PWR_CNT=3000000,GAP_CNT=1000000,POLL_TO=5000000
)(input wire clk,rst,output reg [15:0] dist_mm,
 output reg dist_vld,rs_ok,output reg [3:0] rs_code,output reg dev_found,
 inout wire scl,sda);
reg [7:0] pc,temp,stop_value,last_byte,range_hi,range_lo,spad_info;
reg [47:0] spad_map;
reg [47:0] filtered_map;
reg [5:0] bit_index;
reg [6:0] enabled_count;
reg [31:0] command;
always @* begin
 case(pc)
 8'd0:command=32'h00ff00ff;
 8'd1:command=32'h03c000ff;
 8'd2:command=32'h018900ff;
 8'd3:command=32'h0a8901ff;
 8'd4:command=32'h008800ff;
 8'd5:command=32'h008001ff;
 8'd6:command=32'h00ff01ff;
 8'd7:command=32'h000000ff;
 8'd8:command=32'h029100ff;
 8'd9:command=32'h000001ff;
 8'd10:command=32'h00ff00ff;
 8'd11:command=32'h008000ff;
 8'd12:command=32'h016000ff;
 8'd13:command=32'h0a6012ff;
 8'd14:command=32'h004400ff;
 8'd15:command=32'h004520ff;
 8'd16:command=32'h0001ffff;
 8'd17:command=32'h008001ff;
 8'd18:command=32'h00ff01ff;
 8'd19:command=32'h000000ff;
 8'd20:command=32'h00ff06ff;
 8'd21:command=32'h018300ff;
 8'd22:command=32'h0a8304ff;
 8'd23:command=32'h00ff07ff;
 8'd24:command=32'h008101ff;
 8'd25:command=32'h008001ff;
 8'd26:command=32'h00946bff;
 8'd27:command=32'h008300ff;
 8'd28:command=32'h0b8300ff;
 8'd29:command=32'h008301ff;
 8'd30:command=32'h049200ff;
 8'd31:command=32'h008100ff;
 8'd32:command=32'h00ff06ff;
 8'd33:command=32'h018300ff;
 8'd34:command=32'h0a8300fb;
 8'd35:command=32'h00ff01ff;
 8'd36:command=32'h000001ff;
 8'd37:command=32'h00ff00ff;
 8'd38:command=32'h008000ff;
 8'd39:command=32'h05b000ff;
 8'd40:command=32'h05b101ff;
 8'd41:command=32'h05b202ff;
 8'd42:command=32'h05b303ff;
 8'd43:command=32'h05b404ff;
 8'd44:command=32'h05b505ff;
 8'd45:command=32'h00ff01ff;
 8'd46:command=32'h004f00ff;
 8'd47:command=32'h004e2cff;
 8'd48:command=32'h00ff00ff;
 8'd49:command=32'h00b6b4ff;
 8'd50:command=32'h0cb000ff;
 8'd51:command=32'h0cb101ff;
 8'd52:command=32'h0cb202ff;
 8'd53:command=32'h0cb303ff;
 8'd54:command=32'h0cb404ff;
 8'd55:command=32'h0cb505ff;
 8'd56:command=32'h00ff01ff;
 8'd57:command=32'h000000ff;
 8'd58:command=32'h00ff00ff;
 8'd59:command=32'h000900ff;
 8'd60:command=32'h001000ff;
 8'd61:command=32'h001100ff;
 8'd62:command=32'h002401ff;
 8'd63:command=32'h0025ffff;
 8'd64:command=32'h007500ff;
 8'd65:command=32'h00ff01ff;
 8'd66:command=32'h004e2cff;
 8'd67:command=32'h004800ff;
 8'd68:command=32'h003020ff;
 8'd69:command=32'h00ff00ff;
 8'd70:command=32'h003009ff;
 8'd71:command=32'h005400ff;
 8'd72:command=32'h003104ff;
 8'd73:command=32'h003203ff;
 8'd74:command=32'h004083ff;
 8'd75:command=32'h004625ff;
 8'd76:command=32'h006000ff;
 8'd77:command=32'h002700ff;
 8'd78:command=32'h005006ff;
 8'd79:command=32'h005100ff;
 8'd80:command=32'h005296ff;
 8'd81:command=32'h005608ff;
 8'd82:command=32'h005730ff;
 8'd83:command=32'h006100ff;
 8'd84:command=32'h006200ff;
 8'd85:command=32'h006400ff;
 8'd86:command=32'h006500ff;
 8'd87:command=32'h0066a0ff;
 8'd88:command=32'h00ff01ff;
 8'd89:command=32'h002232ff;
 8'd90:command=32'h004714ff;
 8'd91:command=32'h0049ffff;
 8'd92:command=32'h004a00ff;
 8'd93:command=32'h00ff00ff;
 8'd94:command=32'h007a0aff;
 8'd95:command=32'h007b00ff;
 8'd96:command=32'h007821ff;
 8'd97:command=32'h00ff01ff;
 8'd98:command=32'h002334ff;
 8'd99:command=32'h004200ff;
 8'd100:command=32'h0044ffff;
 8'd101:command=32'h004526ff;
 8'd102:command=32'h004605ff;
 8'd103:command=32'h004040ff;
 8'd104:command=32'h000e06ff;
 8'd105:command=32'h00201aff;
 8'd106:command=32'h004340ff;
 8'd107:command=32'h00ff00ff;
 8'd108:command=32'h003403ff;
 8'd109:command=32'h003544ff;
 8'd110:command=32'h00ff01ff;
 8'd111:command=32'h003104ff;
 8'd112:command=32'h004b09ff;
 8'd113:command=32'h004c05ff;
 8'd114:command=32'h004d04ff;
 8'd115:command=32'h00ff00ff;
 8'd116:command=32'h004400ff;
 8'd117:command=32'h004520ff;
 8'd118:command=32'h004708ff;
 8'd119:command=32'h004828ff;
 8'd120:command=32'h006700ff;
 8'd121:command=32'h007004ff;
 8'd122:command=32'h007101ff;
 8'd123:command=32'h0072feff;
 8'd124:command=32'h007600ff;
 8'd125:command=32'h007700ff;
 8'd126:command=32'h00ff01ff;
 8'd127:command=32'h000d01ff;
 8'd128:command=32'h00ff00ff;
 8'd129:command=32'h008001ff;
 8'd130:command=32'h0001f8ff;
 8'd131:command=32'h00ff01ff;
 8'd132:command=32'h008e01ff;
 8'd133:command=32'h000001ff;
 8'd134:command=32'h00ff00ff;
 8'd135:command=32'h008000ff;
 8'd136:command=32'h000a04ff;
 8'd137:command=32'h018400ff;
 8'd138:command=32'h0a8400ef;
 8'd139:command=32'h000b01ff;
 8'd140:command=32'h000101ff;
 8'd141:command=32'h000041ff;
 8'd142:command=32'h0b130007;
 8'd143:command=32'h000b01ff;
 8'd144:command=32'h000000ff;
 8'd145:command=32'h000102ff;
 8'd146:command=32'h000001ff;
 8'd147:command=32'h0b130007;
 8'd148:command=32'h000b01ff;
 8'd149:command=32'h000000ff;
 8'd150:command=32'h0001e8ff;
 8'd151:command=32'h008001ff;
 8'd152:command=32'h00ff01ff;
 8'd153:command=32'h000000ff;
 8'd154:command=32'h0d9100ff;
 8'd155:command=32'h000001ff;
 8'd156:command=32'h00ff00ff;
 8'd157:command=32'h008000ff;
 8'd158:command=32'h000002ff;
 8'd159:command=32'h0b130007;
 8'd160:command=32'h061400ff;
 8'd161:command=32'h071e00ff;
 8'd162:command=32'h081f00ff;
 8'd163:command=32'h000b01ff;
 8'd164:command=32'h0e0000ff;
 default:command=32'h0e000000;
 endcase
end
wire [7:0] op=command[31:24],addr=command[23:16],value=command[15:8],mask=command[7:0];
wire rd=(op>=1 && op<=8) || op==11;
wire [7:0] wdata=(op==10)?((temp & mask)|value):
 (op==12)?filtered_map[value*8+:8]:(op==13)?stop_value:value;
reg go;
wire [7:0] rdata;
wire rvld,busy,done,ackerr;
i2c_master #(.CLK_HZ(CLK_HZ),.SCL_HZ(SCL_HZ)) u_i2c(
 .clk(clk),.rst(rst),.go(go),.rd(rd),.dev(DEV_ADDR),.idx(addr),.wdata(wdata),
 .nbytes(5'd0),.rdata(rdata),.rvld(rvld),.busy(busy),.done(done),.ackerr(ackerr),.scl(scl),.sda(sda));
reg [1:0] state;
reg [31:0] wait_count,poll_count;
always @(posedge clk) begin
 if(rst) begin
  pc<=0;temp<=0;stop_value<=0;last_byte<=0;range_hi<=0;range_lo<=0;
  filtered_map<=0;bit_index<=0;enabled_count<=0;spad_info<=0;spad_map<=0;go<=0;state<=0;wait_count<=0;poll_count<=0;
  dist_mm<=0;dist_vld<=0;rs_ok<=0;rs_code<=0;dev_found<=0;
 end else begin
  go<=0;dist_vld<=0;
  if(rvld) last_byte<=rdata;
  if(op==11) poll_count<=poll_count+1'b1;
  else poll_count<=0;
  case(state)
   0:if(wait_count>=PWR_CNT) begin wait_count<=0;pc<=0;state<=1;end
     else wait_count<=wait_count+1'b1;
   1:if(op==14) begin
      dist_mm<={range_hi,range_lo};rs_ok<=(rs_code==11);
      dist_vld<=1;pc<=8'd159; // 仅清中断成功后发布完整样本
     end else if(!busy) begin go<=1;state<=2;end
   2:if(done) begin
     if(ackerr || (op==3 && last_byte!=8'hee) || poll_count>=POLL_TO) begin
      rs_ok<=0;dev_found<=0;state<=0;wait_count<=0;pc<=0;
     end else if(op==11 && (last_byte & mask)==0) state<=1;
     else begin
      case(op)
       1:temp<=last_byte;
       2:stop_value<=last_byte;
       3:dev_found<=1;
       4:spad_info<=last_byte;
       5:spad_map[value*8+:8]<=last_byte;
       6:rs_code<=last_byte[6:3];
       7:range_hi<=last_byte;
       8:range_lo<=last_byte;
      endcase
      pc<=pc+1'b1;
      if(op==5 && value==5) begin
       state<=3;bit_index<=0;enabled_count<=0;filtered_map<=0;
      end else state<=1;
     end
    end
   3:begin
     if(!(spad_info[7] && bit_index<12) && enabled_count<spad_info[6:0] && spad_map[bit_index]) begin
      filtered_map[bit_index]<=1;enabled_count<=enabled_count+1'b1;
     end
     if(bit_index==47) state<=1;else bit_index<=bit_index+1'b1;
    end
   default:begin state<=0;wait_count<=0;pc<=0;rs_ok<=0;end
  endcase
 end
end
endmodule
