module lcd_font(input wire [7:0] character,input wire [3:0] row,col,output wire pixel);
reg [34:0] bitmap;
always @* begin
 case(character)
 8'd32:bitmap=35'b00000000000000000000000000000000000;
 8'd48:bitmap=35'b01110100011001110101110011000101110;
 8'd49:bitmap=35'b00100011000010000100001000010001110;
 8'd50:bitmap=35'b01110100010000100010001000100011111;
 8'd51:bitmap=35'b11111000100010000010000011000101110;
 8'd52:bitmap=35'b00010001100101010010111110001000010;
 8'd53:bitmap=35'b11111100001111000001000011000101110;
 8'd54:bitmap=35'b00110010001000011110100011000101110;
 8'd55:bitmap=35'b11111000010001000100010000100001000;
 8'd56:bitmap=35'b01110100011000101110100011000101110;
 8'd57:bitmap=35'b01110100011000101111000010001001100;
 8'd65:bitmap=35'b01110100011000111111100011000110001;
 8'd66:bitmap=35'b11110100011000111110100011000111110;
 8'd67:bitmap=35'b01110100011000010000100001000101110;
 8'd68:bitmap=35'b11100100101000110001100011001011100;
 8'd69:bitmap=35'b11111100001000011110100001000011111;
 8'd70:bitmap=35'b11111100001000011110100001000010000;
 8'd71:bitmap=35'b01110100011000010111100011000101111;
 8'd72:bitmap=35'b10001100011000111111100011000110001;
 8'd73:bitmap=35'b01110001000010000100001000010001110;
 8'd74:bitmap=35'b00111000100001000010000101001001100;
 8'd75:bitmap=35'b10001100101010011000101001001010001;
 8'd76:bitmap=35'b10000100001000010000100001000011111;
 8'd77:bitmap=35'b10001110111010110101100011000110001;
 8'd78:bitmap=35'b10001110011100110101100111001110001;
 8'd79:bitmap=35'b01110100011000110001100011000101110;
 8'd80:bitmap=35'b11110100011000111110100001000010000;
 8'd81:bitmap=35'b01110100011000110001101011001001101;
 8'd82:bitmap=35'b11110100011000111110101001001010001;
 8'd83:bitmap=35'b01111100001000001110000010000111110;
 8'd84:bitmap=35'b11111001000010000100001000010000100;
 8'd85:bitmap=35'b10001100011000110001100011000101110;
 8'd86:bitmap=35'b10001100011000110001100010101000100;
 8'd87:bitmap=35'b10001100011000110101101011101110001;
 8'd88:bitmap=35'b10001100010101000100010101000110001;
 8'd89:bitmap=35'b10001100010101000100001000010000100;
 8'd90:bitmap=35'b11111000010001000100010001000011111;
 8'd58:bitmap=35'b00000001000010000000001000010000000;
 8'd45:bitmap=35'b00000000000000011111000000000000000;
 8'd46:bitmap=35'b00000000000000000000000000110001100;
 8'd44:bitmap=35'b00000000000000000000001100010001000;
 8'd47:bitmap=35'b00001000100010001000100000000000000;
 8'd92:bitmap=35'b10000010000010000010000010000000000;
 8'd61:bitmap=35'b00000000001111100000111110000000000;
 8'd43:bitmap=35'b00000001000010011111001000010000000;
 8'd42:bitmap=35'b00000101010111011111011101010100000;
 8'd37:bitmap=35'b10001000100010000100010001000100001;
 8'd40:bitmap=35'b00010001000100001000010000010000010;
 8'd41:bitmap=35'b01000001000001000010000100010001000;
 8'd35:bitmap=35'b01010111110101001010111110101000000;
 8'd33:bitmap=35'b00100001000010000100001000000000100;
 8'd63:bitmap=35'b01110100010000100110001000000000100;
 8'd60:bitmap=35'b00010001000100010000010000010000010;
 8'd62:bitmap=35'b01000001000001000001000100010001000;
 8'd95:bitmap=35'b00000000000000000000000000000011111;
 default:bitmap=0;
 endcase
end
wire ascii_px=(row[3:1]<3'd7 && col[3:1]<3'd5)?bitmap[34-row[3:1]*5-col[3:1]]:1'b0;

// ---------------------------------------------------------------------------
// 汉字支路：32 字 x 16 行 = 512 项，键 = {字索引[4:0], 行[3:0]}
//   与 ASCII 支路并行求值，互不串联。
// ---------------------------------------------------------------------------
reg [15:0] cjk_row_bits;
always @* begin
 case({character[4:0],row})
 // 0x80 声
 9'h000:cjk_row_bits=16'h0100; 9'h001:cjk_row_bits=16'h0100;
 9'h002:cjk_row_bits=16'hFFFE; 9'h003:cjk_row_bits=16'h0100;
 9'h004:cjk_row_bits=16'h7FFC; 9'h005:cjk_row_bits=16'h0000;
 9'h006:cjk_row_bits=16'h3FF8; 9'h007:cjk_row_bits=16'h2108;
 9'h008:cjk_row_bits=16'h2108; 9'h009:cjk_row_bits=16'h3FF8;
 9'h00A:cjk_row_bits=16'h2000; 9'h00B:cjk_row_bits=16'h2000;
 9'h00C:cjk_row_bits=16'h2000; 9'h00D:cjk_row_bits=16'h4000;
 9'h00E:cjk_row_bits=16'h4000; 9'h00F:cjk_row_bits=16'h8000;
 // 0x81 部
 9'h010:cjk_row_bits=16'h1000; 9'h011:cjk_row_bits=16'h083E;
 9'h012:cjk_row_bits=16'h7FA2; 9'h013:cjk_row_bits=16'h0024;
 9'h014:cjk_row_bits=16'h2124; 9'h015:cjk_row_bits=16'h1228;
 9'h016:cjk_row_bits=16'hFFE4; 9'h017:cjk_row_bits=16'h0024;
 9'h018:cjk_row_bits=16'h0022; 9'h019:cjk_row_bits=16'h3F22;
 9'h01A:cjk_row_bits=16'h2122; 9'h01B:cjk_row_bits=16'h2134;
 9'h01C:cjk_row_bits=16'h2128; 9'h01D:cjk_row_bits=16'h3F20;
 9'h01E:cjk_row_bits=16'h2120; 9'h01F:cjk_row_bits=16'h0020;
 // 0x82 音
 9'h020:cjk_row_bits=16'h0200; 9'h021:cjk_row_bits=16'h0100;
 9'h022:cjk_row_bits=16'h3FF8; 9'h023:cjk_row_bits=16'h0000;
 9'h024:cjk_row_bits=16'h0820; 9'h025:cjk_row_bits=16'h0440;
 9'h026:cjk_row_bits=16'hFFFE; 9'h027:cjk_row_bits=16'h0000;
 9'h028:cjk_row_bits=16'h1FF0; 9'h029:cjk_row_bits=16'h1010;
 9'h02A:cjk_row_bits=16'h1010; 9'h02B:cjk_row_bits=16'h1FF0;
 9'h02C:cjk_row_bits=16'h1010; 9'h02D:cjk_row_bits=16'h1010;
 9'h02E:cjk_row_bits=16'h1FF0; 9'h02F:cjk_row_bits=16'h1010;
 // 0x83 ɫ
 9'h030:cjk_row_bits=16'h0800; 9'h031:cjk_row_bits=16'h0800;
 9'h032:cjk_row_bits=16'h1FE0; 9'h033:cjk_row_bits=16'h2020;
 9'h034:cjk_row_bits=16'h4040; 9'h035:cjk_row_bits=16'hBFF8;
 9'h036:cjk_row_bits=16'h2108; 9'h037:cjk_row_bits=16'h2108;
 9'h038:cjk_row_bits=16'h2108; 9'h039:cjk_row_bits=16'h3FF8;
 9'h03A:cjk_row_bits=16'h2000; 9'h03B:cjk_row_bits=16'h2002;
 9'h03C:cjk_row_bits=16'h2002; 9'h03D:cjk_row_bits=16'h2002;
 9'h03E:cjk_row_bits=16'h1FFE; 9'h03F:cjk_row_bits=16'h0000;
 // 0x84 变
 9'h040:cjk_row_bits=16'h0200; 9'h041:cjk_row_bits=16'h0100;
 9'h042:cjk_row_bits=16'hFFFE; 9'h043:cjk_row_bits=16'h0440;
 9'h044:cjk_row_bits=16'h1450; 9'h045:cjk_row_bits=16'h2448;
 9'h046:cjk_row_bits=16'h4444; 9'h047:cjk_row_bits=16'h0000;
 9'h048:cjk_row_bits=16'h3FF0; 9'h049:cjk_row_bits=16'h0820;
 9'h04A:cjk_row_bits=16'h0440; 9'h04B:cjk_row_bits=16'h0280;
 9'h04C:cjk_row_bits=16'h0100; 9'h04D:cjk_row_bits=16'h06C0;
 9'h04E:cjk_row_bits=16'h1830; 9'h04F:cjk_row_bits=16'hE00E;
 // 0x85 调
 9'h050:cjk_row_bits=16'h0000; 9'h051:cjk_row_bits=16'h47FC;
 9'h052:cjk_row_bits=16'h2444; 9'h053:cjk_row_bits=16'h2444;
 9'h054:cjk_row_bits=16'h05F4; 9'h055:cjk_row_bits=16'h0444;
 9'h056:cjk_row_bits=16'hE444; 9'h057:cjk_row_bits=16'h27FC;
 9'h058:cjk_row_bits=16'h2404; 9'h059:cjk_row_bits=16'h25F4;
 9'h05A:cjk_row_bits=16'h2514; 9'h05B:cjk_row_bits=16'h2D14;
 9'h05C:cjk_row_bits=16'h35F4; 9'h05D:cjk_row_bits=16'h2404;
 9'h05E:cjk_row_bits=16'h0414; 9'h05F:cjk_row_bits=16'h0808;
 // 0x86 颤
 9'h060:cjk_row_bits=16'h0800; 9'h061:cjk_row_bits=16'hFF7E;
 9'h062:cjk_row_bits=16'h0010; 9'h063:cjk_row_bits=16'hFF20;
 9'h064:cjk_row_bits=16'h817C; 9'h065:cjk_row_bits=16'hBD44;
 9'h066:cjk_row_bits=16'hA554; 9'h067:cjk_row_bits=16'hFF54;
 9'h068:cjk_row_bits=16'h0054; 9'h069:cjk_row_bits=16'h7E54;
 9'h06A:cjk_row_bits=16'h4254; 9'h06B:cjk_row_bits=16'h7E54;
 9'h06C:cjk_row_bits=16'h4220; 9'h06D:cjk_row_bits=16'h7E28;
 9'h06E:cjk_row_bits=16'h0044; 9'h06F:cjk_row_bits=16'hFE82;
 // 0x87 延
 9'h070:cjk_row_bits=16'h0008; 9'h071:cjk_row_bits=16'h003C;
 9'h072:cjk_row_bits=16'hF9E0; 9'h073:cjk_row_bits=16'h0820;
 9'h074:cjk_row_bits=16'h1020; 9'h075:cjk_row_bits=16'h1120;
 9'h076:cjk_row_bits=16'h213C; 9'h077:cjk_row_bits=16'h7920;
 9'h078:cjk_row_bits=16'h0920; 9'h079:cjk_row_bits=16'h0920;
 9'h07A:cjk_row_bits=16'h4920; 9'h07B:cjk_row_bits=16'h31FC;
 9'h07C:cjk_row_bits=16'h1000; 9'h07D:cjk_row_bits=16'h2C00;
 9'h07E:cjk_row_bits=16'h43FE; 9'h07F:cjk_row_bits=16'h8000;
 // 0x88 ʱ
 9'h080:cjk_row_bits=16'h0008; 9'h081:cjk_row_bits=16'h0008;
 9'h082:cjk_row_bits=16'h7C08; 9'h083:cjk_row_bits=16'h4408;
 9'h084:cjk_row_bits=16'h45FE; 9'h085:cjk_row_bits=16'h4408;
 9'h086:cjk_row_bits=16'h4408; 9'h087:cjk_row_bits=16'h7C08;
 9'h088:cjk_row_bits=16'h4488; 9'h089:cjk_row_bits=16'h4448;
 9'h08A:cjk_row_bits=16'h4448; 9'h08B:cjk_row_bits=16'h4408;
 9'h08C:cjk_row_bits=16'h7C08; 9'h08D:cjk_row_bits=16'h4408;
 9'h08E:cjk_row_bits=16'h0028; 9'h08F:cjk_row_bits=16'h0010;
 // 0x89 开
 9'h090:cjk_row_bits=16'h0000; 9'h091:cjk_row_bits=16'h7FFC;
 9'h092:cjk_row_bits=16'h0820; 9'h093:cjk_row_bits=16'h0820;
 9'h094:cjk_row_bits=16'h0820; 9'h095:cjk_row_bits=16'h0820;
 9'h096:cjk_row_bits=16'h0820; 9'h097:cjk_row_bits=16'hFFFE;
 9'h098:cjk_row_bits=16'h0820; 9'h099:cjk_row_bits=16'h0820;
 9'h09A:cjk_row_bits=16'h0820; 9'h09B:cjk_row_bits=16'h0820;
 9'h09C:cjk_row_bits=16'h1020; 9'h09D:cjk_row_bits=16'h1020;
 9'h09E:cjk_row_bits=16'h2020; 9'h09F:cjk_row_bits=16'h4020;
 // 0x8A 关
 9'h0A0:cjk_row_bits=16'h1010; 9'h0A1:cjk_row_bits=16'h0810;
 9'h0A2:cjk_row_bits=16'h0820; 9'h0A3:cjk_row_bits=16'h0000;
 9'h0A4:cjk_row_bits=16'h3FF8; 9'h0A5:cjk_row_bits=16'h0100;
 9'h0A6:cjk_row_bits=16'h0100; 9'h0A7:cjk_row_bits=16'h0100;
 9'h0A8:cjk_row_bits=16'hFFFE; 9'h0A9:cjk_row_bits=16'h0100;
 9'h0AA:cjk_row_bits=16'h0280; 9'h0AB:cjk_row_bits=16'h0280;
 9'h0AC:cjk_row_bits=16'h0440; 9'h0AD:cjk_row_bits=16'h0820;
 9'h0AE:cjk_row_bits=16'h3018; 9'h0AF:cjk_row_bits=16'hC006;
 // 0x8B 量
 9'h0B0:cjk_row_bits=16'h0000; 9'h0B1:cjk_row_bits=16'h1FF0;
 9'h0B2:cjk_row_bits=16'h1010; 9'h0B3:cjk_row_bits=16'h1FF0;
 9'h0B4:cjk_row_bits=16'h1010; 9'h0B5:cjk_row_bits=16'hFFFE;
 9'h0B6:cjk_row_bits=16'h0000; 9'h0B7:cjk_row_bits=16'h1FF0;
 9'h0B8:cjk_row_bits=16'h1110; 9'h0B9:cjk_row_bits=16'h1FF0;
 9'h0BA:cjk_row_bits=16'h1110; 9'h0BB:cjk_row_bits=16'h1FF0;
 9'h0BC:cjk_row_bits=16'h0100; 9'h0BD:cjk_row_bits=16'h1FF0;
 9'h0BE:cjk_row_bits=16'h0100; 9'h0BF:cjk_row_bits=16'h7FFC;
 // 0x8C 距
 9'h0C0:cjk_row_bits=16'h0000; 9'h0C1:cjk_row_bits=16'h7DFE;
 9'h0C2:cjk_row_bits=16'h4500; 9'h0C3:cjk_row_bits=16'h4500;
 9'h0C4:cjk_row_bits=16'h4500; 9'h0C5:cjk_row_bits=16'h7DFC;
 9'h0C6:cjk_row_bits=16'h1104; 9'h0C7:cjk_row_bits=16'h1104;
 9'h0C8:cjk_row_bits=16'h5D04; 9'h0C9:cjk_row_bits=16'h5104;
 9'h0CA:cjk_row_bits=16'h51FC; 9'h0CB:cjk_row_bits=16'h5100;
 9'h0CC:cjk_row_bits=16'h5D00; 9'h0CD:cjk_row_bits=16'hE100;
 9'h0CE:cjk_row_bits=16'h01FE; 9'h0CF:cjk_row_bits=16'h0000;
 // 0x8D 毫
 9'h0D0:cjk_row_bits=16'h0100; 9'h0D1:cjk_row_bits=16'h7FFC;
 9'h0D2:cjk_row_bits=16'h0000; 9'h0D3:cjk_row_bits=16'h1FF0;
 9'h0D4:cjk_row_bits=16'h1010; 9'h0D5:cjk_row_bits=16'h1FF0;
 9'h0D6:cjk_row_bits=16'h0000; 9'h0D7:cjk_row_bits=16'h7FFE;
 9'h0D8:cjk_row_bits=16'h4002; 9'h0D9:cjk_row_bits=16'h81F4;
 9'h0DA:cjk_row_bits=16'h3E00; 9'h0DB:cjk_row_bits=16'h03F0;
 9'h0DC:cjk_row_bits=16'h3E00; 9'h0DD:cjk_row_bits=16'h03FA;
 9'h0DE:cjk_row_bits=16'h7E02; 9'h0DF:cjk_row_bits=16'h01FE;
 // 0x8E 米
 9'h0E0:cjk_row_bits=16'h0100; 9'h0E1:cjk_row_bits=16'h2108;
 9'h0E2:cjk_row_bits=16'h1108; 9'h0E3:cjk_row_bits=16'h0910;
 9'h0E4:cjk_row_bits=16'h0920; 9'h0E5:cjk_row_bits=16'h0100;
 9'h0E6:cjk_row_bits=16'h7FFC; 9'h0E7:cjk_row_bits=16'h0380;
 9'h0E8:cjk_row_bits=16'h0540; 9'h0E9:cjk_row_bits=16'h0540;
 9'h0EA:cjk_row_bits=16'h0920; 9'h0EB:cjk_row_bits=16'h1110;
 9'h0EC:cjk_row_bits=16'h2108; 9'h0ED:cjk_row_bits=16'hC106;
 9'h0EE:cjk_row_bits=16'h0100; 9'h0EF:cjk_row_bits=16'h0100;
 // 0x8F 半
 9'h0F0:cjk_row_bits=16'h0100; 9'h0F1:cjk_row_bits=16'h2108;
 9'h0F2:cjk_row_bits=16'h1108; 9'h0F3:cjk_row_bits=16'h0910;
 9'h0F4:cjk_row_bits=16'h0920; 9'h0F5:cjk_row_bits=16'h0100;
 9'h0F6:cjk_row_bits=16'h3FF8; 9'h0F7:cjk_row_bits=16'h0100;
 9'h0F8:cjk_row_bits=16'h0100; 9'h0F9:cjk_row_bits=16'h0100;
 9'h0FA:cjk_row_bits=16'hFFFE; 9'h0FB:cjk_row_bits=16'h0100;
 9'h0FC:cjk_row_bits=16'h0100; 9'h0FD:cjk_row_bits=16'h0100;
 9'h0FE:cjk_row_bits=16'h0100; 9'h0FF:cjk_row_bits=16'h0100;
 // 0x90 域
 9'h100:cjk_row_bits=16'h2014; 9'h101:cjk_row_bits=16'h2012;
 9'h102:cjk_row_bits=16'h2010; 9'h103:cjk_row_bits=16'h27FE;
 9'h104:cjk_row_bits=16'h2010; 9'h105:cjk_row_bits=16'hF810;
 9'h106:cjk_row_bits=16'h23D2; 9'h107:cjk_row_bits=16'h2252;
 9'h108:cjk_row_bits=16'h2252; 9'h109:cjk_row_bits=16'h2254;
 9'h10A:cjk_row_bits=16'h23D4; 9'h10B:cjk_row_bits=16'h3808;
 9'h10C:cjk_row_bits=16'hE0EA; 9'h10D:cjk_row_bits=16'h471A;
 9'h10E:cjk_row_bits=16'h0226; 9'h10F:cjk_row_bits=16'h0042;
 // 0x91 浏
 9'h110:cjk_row_bits=16'h0204; 9'h111:cjk_row_bits=16'h4104;
 9'h112:cjk_row_bits=16'h2104; 9'h113:cjk_row_bits=16'h2FE4;
 9'h114:cjk_row_bits=16'h0094; 9'h115:cjk_row_bits=16'h8494;
 9'h116:cjk_row_bits=16'h4294; 9'h117:cjk_row_bits=16'h5294;
 9'h118:cjk_row_bits=16'h1114; 9'h119:cjk_row_bits=16'h2114;
 9'h11A:cjk_row_bits=16'hE294; 9'h11B:cjk_row_bits=16'h2294;
 9'h11C:cjk_row_bits=16'h2444; 9'h11D:cjk_row_bits=16'h2844;
 9'h11E:cjk_row_bits=16'h3014; 9'h11F:cjk_row_bits=16'h0008;
 // 0x92 览
 9'h120:cjk_row_bits=16'h0440; 9'h121:cjk_row_bits=16'h2440;
 9'h122:cjk_row_bits=16'h247C; 9'h123:cjk_row_bits=16'h2490;
 9'h124:cjk_row_bits=16'h2508; 9'h125:cjk_row_bits=16'h0400;
 9'h126:cjk_row_bits=16'h1FF0; 9'h127:cjk_row_bits=16'h1010;
 9'h128:cjk_row_bits=16'h1110; 9'h129:cjk_row_bits=16'h1110;
 9'h12A:cjk_row_bits=16'h1110; 9'h12B:cjk_row_bits=16'h1290;
 9'h12C:cjk_row_bits=16'h0280; 9'h12D:cjk_row_bits=16'h0484;
 9'h12E:cjk_row_bits=16'h1884; 9'h12F:cjk_row_bits=16'h607C;
 // 0x93 整
 9'h130:cjk_row_bits=16'h0820; 9'h131:cjk_row_bits=16'h0820;
 9'h132:cjk_row_bits=16'hFFBE; 9'h133:cjk_row_bits=16'h0844;
 9'h134:cjk_row_bits=16'h7FA4; 9'h135:cjk_row_bits=16'h4924;
 9'h136:cjk_row_bits=16'h7F28; 9'h137:cjk_row_bits=16'h2A10;
 9'h138:cjk_row_bits=16'h4928; 9'h139:cjk_row_bits=16'h8846;
 9'h13A:cjk_row_bits=16'h0000; 9'h13B:cjk_row_bits=16'h7FFC;
 9'h13C:cjk_row_bits=16'h0100; 9'h13D:cjk_row_bits=16'h11F8;
 9'h13E:cjk_row_bits=16'h1100; 9'h13F:cjk_row_bits=16'hFFFE;
 // 0x94 测
 9'h140:cjk_row_bits=16'h0004; 9'h141:cjk_row_bits=16'h27C4;
 9'h142:cjk_row_bits=16'h1444; 9'h143:cjk_row_bits=16'h1454;
 9'h144:cjk_row_bits=16'h8554; 9'h145:cjk_row_bits=16'h4554;
 9'h146:cjk_row_bits=16'h4554; 9'h147:cjk_row_bits=16'h1554;
 9'h148:cjk_row_bits=16'h1554; 9'h149:cjk_row_bits=16'h2554;
 9'h14A:cjk_row_bits=16'hE554; 9'h14B:cjk_row_bits=16'h2104;
 9'h14C:cjk_row_bits=16'h2284; 9'h14D:cjk_row_bits=16'h2244;
 9'h14E:cjk_row_bits=16'h2414; 9'h14F:cjk_row_bits=16'h0808;
 // 0x95 试
 9'h150:cjk_row_bits=16'h0028; 9'h151:cjk_row_bits=16'h2024;
 9'h152:cjk_row_bits=16'h1024; 9'h153:cjk_row_bits=16'h1020;
 9'h154:cjk_row_bits=16'h07FE; 9'h155:cjk_row_bits=16'h0020;
 9'h156:cjk_row_bits=16'hF020; 9'h157:cjk_row_bits=16'h17E0;
 9'h158:cjk_row_bits=16'h1120; 9'h159:cjk_row_bits=16'h1110;
 9'h15A:cjk_row_bits=16'h1110; 9'h15B:cjk_row_bits=16'h1510;
 9'h15C:cjk_row_bits=16'h19CA; 9'h15D:cjk_row_bits=16'h170A;
 9'h15E:cjk_row_bits=16'h0206; 9'h15F:cjk_row_bits=16'h0002;
 // 0x96 正
 9'h160:cjk_row_bits=16'h0000; 9'h161:cjk_row_bits=16'h7FFC;
 9'h162:cjk_row_bits=16'h0100; 9'h163:cjk_row_bits=16'h0100;
 9'h164:cjk_row_bits=16'h0100; 9'h165:cjk_row_bits=16'h0100;
 9'h166:cjk_row_bits=16'h1100; 9'h167:cjk_row_bits=16'h11F8;
 9'h168:cjk_row_bits=16'h1100; 9'h169:cjk_row_bits=16'h1100;
 9'h16A:cjk_row_bits=16'h1100; 9'h16B:cjk_row_bits=16'h1100;
 9'h16C:cjk_row_bits=16'h1100; 9'h16D:cjk_row_bits=16'h1100;
 9'h16E:cjk_row_bits=16'hFFFE; 9'h16F:cjk_row_bits=16'h0000;
 // 0x97 常
 9'h170:cjk_row_bits=16'h0100; 9'h171:cjk_row_bits=16'h1110;
 9'h172:cjk_row_bits=16'h0920; 9'h173:cjk_row_bits=16'h7FFE;
 9'h174:cjk_row_bits=16'h4002; 9'h175:cjk_row_bits=16'h9FF4;
 9'h176:cjk_row_bits=16'h1010; 9'h177:cjk_row_bits=16'h1FF0;
 9'h178:cjk_row_bits=16'h0100; 9'h179:cjk_row_bits=16'h3FF8;
 9'h17A:cjk_row_bits=16'h2108; 9'h17B:cjk_row_bits=16'h2108;
 9'h17C:cjk_row_bits=16'h2128; 9'h17D:cjk_row_bits=16'h2110;
 9'h17E:cjk_row_bits=16'h0100; 9'h17F:cjk_row_bits=16'h0100;
 // 0x98 长
 9'h180:cjk_row_bits=16'h0800; 9'h181:cjk_row_bits=16'h0810;
 9'h182:cjk_row_bits=16'h0820; 9'h183:cjk_row_bits=16'h0840;
 9'h184:cjk_row_bits=16'h0880; 9'h185:cjk_row_bits=16'h0900;
 9'h186:cjk_row_bits=16'h0800; 9'h187:cjk_row_bits=16'hFFFE;
 9'h188:cjk_row_bits=16'h0A00; 9'h189:cjk_row_bits=16'h0900;
 9'h18A:cjk_row_bits=16'h0880; 9'h18B:cjk_row_bits=16'h0840;
 9'h18C:cjk_row_bits=16'h0920; 9'h18D:cjk_row_bits=16'h0A18;
 9'h18E:cjk_row_bits=16'h0C06; 9'h18F:cjk_row_bits=16'h0800;
 // 0x99 笛
 9'h190:cjk_row_bits=16'h1040; 9'h191:cjk_row_bits=16'h1040;
 9'h192:cjk_row_bits=16'h3F7E; 9'h193:cjk_row_bits=16'h2890;
 9'h194:cjk_row_bits=16'h4508; 9'h195:cjk_row_bits=16'h8100;
 9'h196:cjk_row_bits=16'h3FF8; 9'h197:cjk_row_bits=16'h2108;
 9'h198:cjk_row_bits=16'h2108; 9'h199:cjk_row_bits=16'h2108;
 9'h19A:cjk_row_bits=16'h3FF8; 9'h19B:cjk_row_bits=16'h2108;
 9'h19C:cjk_row_bits=16'h2108; 9'h19D:cjk_row_bits=16'h2108;
 9'h19E:cjk_row_bits=16'h3FF8; 9'h19F:cjk_row_bits=16'h2008;
 // 0x9A 锯
 9'h1A0:cjk_row_bits=16'h2000; 9'h1A1:cjk_row_bits=16'h23FC;
 9'h1A2:cjk_row_bits=16'h3A04; 9'h1A3:cjk_row_bits=16'h2204;
 9'h1A4:cjk_row_bits=16'h43FC; 9'h1A5:cjk_row_bits=16'h7A20;
 9'h1A6:cjk_row_bits=16'hA220; 9'h1A7:cjk_row_bits=16'h23FE;
 9'h1A8:cjk_row_bits=16'hFA20; 9'h1A9:cjk_row_bits=16'h2220;
 9'h1AA:cjk_row_bits=16'h22FC; 9'h1AB:cjk_row_bits=16'h2284;
 9'h1AC:cjk_row_bits=16'h2A84; 9'h1AD:cjk_row_bits=16'h3484;
 9'h1AE:cjk_row_bits=16'h24FC; 9'h1AF:cjk_row_bits=16'h0884;
 // 0x9B 齿
 9'h1B0:cjk_row_bits=16'h0100; 9'h1B1:cjk_row_bits=16'h0100;
 9'h1B2:cjk_row_bits=16'h11F8; 9'h1B3:cjk_row_bits=16'h1100;
 9'h1B4:cjk_row_bits=16'h1100; 9'h1B5:cjk_row_bits=16'h1100;
 9'h1B6:cjk_row_bits=16'hFFFE; 9'h1B7:cjk_row_bits=16'h0000;
 9'h1B8:cjk_row_bits=16'h2108; 9'h1B9:cjk_row_bits=16'h2108;
 9'h1BA:cjk_row_bits=16'h2288; 9'h1BB:cjk_row_bits=16'h2448;
 9'h1BC:cjk_row_bits=16'h2828; 9'h1BD:cjk_row_bits=16'h2008;
 9'h1BE:cjk_row_bits=16'h3FF8; 9'h1BF:cjk_row_bits=16'h0008;
 // 0x9C 单
 9'h1C0:cjk_row_bits=16'h1010; 9'h1C1:cjk_row_bits=16'h0820;
 9'h1C2:cjk_row_bits=16'h0440; 9'h1C3:cjk_row_bits=16'h3FF8;
 9'h1C4:cjk_row_bits=16'h2108; 9'h1C5:cjk_row_bits=16'h2108;
 9'h1C6:cjk_row_bits=16'h3FF8; 9'h1C7:cjk_row_bits=16'h2108;
 9'h1C8:cjk_row_bits=16'h2108; 9'h1C9:cjk_row_bits=16'h3FF8;
 9'h1CA:cjk_row_bits=16'h0100; 9'h1CB:cjk_row_bits=16'h0100;
 9'h1CC:cjk_row_bits=16'hFFFE; 9'h1CD:cjk_row_bits=16'h0100;
 9'h1CE:cjk_row_bits=16'h0100; 9'h1CF:cjk_row_bits=16'h0100;
 // 0x9D 簧
 9'h1D0:cjk_row_bits=16'h2040; 9'h1D1:cjk_row_bits=16'h3E7E;
 9'h1D2:cjk_row_bits=16'h4890; 9'h1D3:cjk_row_bits=16'h8440;
 9'h1D4:cjk_row_bits=16'h3FF8; 9'h1D5:cjk_row_bits=16'h0440;
 9'h1D6:cjk_row_bits=16'hFFFE; 9'h1D7:cjk_row_bits=16'h0100;
 9'h1D8:cjk_row_bits=16'h3FF8; 9'h1D9:cjk_row_bits=16'h2108;
 9'h1DA:cjk_row_bits=16'h3FF8; 9'h1DB:cjk_row_bits=16'h2108;
 9'h1DC:cjk_row_bits=16'h3FF8; 9'h1DD:cjk_row_bits=16'h0820;
 9'h1DE:cjk_row_bits=16'h1010; 9'h1DF:cjk_row_bits=16'h2008;
 // 0x9E 三
 9'h1E0:cjk_row_bits=16'h0000; 9'h1E1:cjk_row_bits=16'h0000;
 9'h1E2:cjk_row_bits=16'h7FFC; 9'h1E3:cjk_row_bits=16'h0000;
 9'h1E4:cjk_row_bits=16'h0000; 9'h1E5:cjk_row_bits=16'h0000;
 9'h1E6:cjk_row_bits=16'h0000; 9'h1E7:cjk_row_bits=16'h3FF8;
 9'h1E8:cjk_row_bits=16'h0000; 9'h1E9:cjk_row_bits=16'h0000;
 9'h1EA:cjk_row_bits=16'h0000; 9'h1EB:cjk_row_bits=16'h0000;
 9'h1EC:cjk_row_bits=16'h0000; 9'h1ED:cjk_row_bits=16'hFFFE;
 9'h1EE:cjk_row_bits=16'h0000; 9'h1EF:cjk_row_bits=16'h0000;
 // 0x9F 角
 9'h1F0:cjk_row_bits=16'h0800; 9'h1F1:cjk_row_bits=16'h0800;
 9'h1F2:cjk_row_bits=16'h1FE0; 9'h1F3:cjk_row_bits=16'h2020;
 9'h1F4:cjk_row_bits=16'h4040; 9'h1F5:cjk_row_bits=16'hBFF8;
 9'h1F6:cjk_row_bits=16'h2108; 9'h1F7:cjk_row_bits=16'h2108;
 9'h1F8:cjk_row_bits=16'h3FF8; 9'h1F9:cjk_row_bits=16'h2108;
 9'h1FA:cjk_row_bits=16'h2108; 9'h1FB:cjk_row_bits=16'h3FF8;
 9'h1FC:cjk_row_bits=16'h2108; 9'h1FD:cjk_row_bits=16'h4108;
 9'h1FE:cjk_row_bits=16'h4128; 9'h1FF:cjk_row_bits=16'h8010;
 default:cjk_row_bits=16'h0000;
 endcase
end

// 最后一级：1 个 LUT，两支并行结果二选一。character[7] 是"这是汉字"的标志位
assign pixel=character[7]?cjk_row_bits[15-col]:ascii_px;
endmodule
