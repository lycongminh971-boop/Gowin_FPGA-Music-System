module song_ram #(
 parameter integer AW=11,
 parameter integer DEPTH=2048,
 parameter integer WITH_INIT=1     // 1=写入内置曲（曲谱区）0=全 0（录音区）
)(
 input  wire clk,
 input  wire we,
 input  wire [AW-1:0] waddr,
 input  wire [7:0]     wdata,
 input  wire [AW-1:0] raddr,
 output reg  [7:0]     rdata
);
reg [7:0] mem[0:DEPTH-1];

// 只有 DEPTH 覆盖到槽位 0（前 512 字节）时才需要内置曲；写成 generate 分支
// 是为了 DEPTH 被改小时不会越界。DEPTH=2048 默认走上面的正式路径。
generate
 if (WITH_INIT != 0 && DEPTH >= 512) begin : g_builtin
  initial begin
   // ---- 句 1：3 3 4 5 | 5 4 3 2 | 1 1 2 3 | 3. 2 2 ----
   mem[  0]=8'd16; mem[  1]=8'd0; mem[  2]=8'd0; mem[  3]=8'd4;  // E4
   mem[  4]=8'd16; mem[  5]=8'd0; mem[  6]=8'd0; mem[  7]=8'd4;  // E4
   mem[  8]=8'd32; mem[  9]=8'd0; mem[ 10]=8'd0; mem[ 11]=8'd4;  // F4
   mem[ 12]=8'd128; mem[ 13]=8'd0; mem[ 14]=8'd0; mem[ 15]=8'd4;  // G4
   mem[ 16]=8'd128; mem[ 17]=8'd0; mem[ 18]=8'd0; mem[ 19]=8'd4;  // G4
   mem[ 20]=8'd32; mem[ 21]=8'd0; mem[ 22]=8'd0; mem[ 23]=8'd4;  // F4
   mem[ 24]=8'd16; mem[ 25]=8'd0; mem[ 26]=8'd0; mem[ 27]=8'd4;  // E4
   mem[ 28]=8'd 4; mem[ 29]=8'd0; mem[ 30]=8'd0; mem[ 31]=8'd4;  // D4
   mem[ 32]=8'd 1; mem[ 33]=8'd0; mem[ 34]=8'd0; mem[ 35]=8'd4;  // C4
   mem[ 36]=8'd 1; mem[ 37]=8'd0; mem[ 38]=8'd0; mem[ 39]=8'd4;  // C4
   mem[ 40]=8'd 4; mem[ 41]=8'd0; mem[ 42]=8'd0; mem[ 43]=8'd4;  // D4
   mem[ 44]=8'd16; mem[ 45]=8'd0; mem[ 46]=8'd0; mem[ 47]=8'd4;  // E4
   mem[ 48]=8'd16; mem[ 49]=8'd0; mem[ 50]=8'd0; mem[ 51]=8'd6;  // E4 附点四分
   mem[ 52]=8'd 4; mem[ 53]=8'd0; mem[ 54]=8'd0; mem[ 55]=8'd2;  // D4 八分
   mem[ 56]=8'd 4; mem[ 57]=8'd0; mem[ 58]=8'd0; mem[ 59]=8'd8;  // D4 二分
   // ---- 句 2：3 3 4 5 | 5 4 3 2 | 1 1 2 3 | 2. 1 1 ----
   mem[ 60]=8'd16; mem[ 61]=8'd0; mem[ 62]=8'd0; mem[ 63]=8'd4;  // E4
   mem[ 64]=8'd16; mem[ 65]=8'd0; mem[ 66]=8'd0; mem[ 67]=8'd4;  // E4
   mem[ 68]=8'd32; mem[ 69]=8'd0; mem[ 70]=8'd0; mem[ 71]=8'd4;  // F4
   mem[ 72]=8'd128; mem[ 73]=8'd0; mem[ 74]=8'd0; mem[ 75]=8'd4;  // G4
   mem[ 76]=8'd128; mem[ 77]=8'd0; mem[ 78]=8'd0; mem[ 79]=8'd4;  // G4
   mem[ 80]=8'd32; mem[ 81]=8'd0; mem[ 82]=8'd0; mem[ 83]=8'd4;  // F4
   mem[ 84]=8'd16; mem[ 85]=8'd0; mem[ 86]=8'd0; mem[ 87]=8'd4;  // E4
   mem[ 88]=8'd 4; mem[ 89]=8'd0; mem[ 90]=8'd0; mem[ 91]=8'd4;  // D4
   mem[ 92]=8'd 1; mem[ 93]=8'd0; mem[ 94]=8'd0; mem[ 95]=8'd4;  // C4
   mem[ 96]=8'd 1; mem[ 97]=8'd0; mem[ 98]=8'd0; mem[ 99]=8'd4;  // C4
   mem[100]=8'd 4; mem[101]=8'd0; mem[102]=8'd0; mem[103]=8'd4;  // D4
   mem[104]=8'd16; mem[105]=8'd0; mem[106]=8'd0; mem[107]=8'd4;  // E4
   mem[108]=8'd 4; mem[109]=8'd0; mem[110]=8'd0; mem[111]=8'd6;  // D4 附点四分
   mem[112]=8'd 1; mem[113]=8'd0; mem[114]=8'd0; mem[115]=8'd2;  // C4 八分
   mem[116]=8'd 1; mem[117]=8'd0; mem[118]=8'd0; mem[119]=8'd8;  // C4 二分
   // ---- 句 3：2 2 3 1 | 2 3 4 3 1 | 2 3 4 3 2 | 1 2 5 ----
   mem[120]=8'd 4; mem[121]=8'd0; mem[122]=8'd0; mem[123]=8'd4;  // D4
   mem[124]=8'd 4; mem[125]=8'd0; mem[126]=8'd0; mem[127]=8'd4;  // D4
   mem[128]=8'd16; mem[129]=8'd0; mem[130]=8'd0; mem[131]=8'd4;  // E4
   mem[132]=8'd 1; mem[133]=8'd0; mem[134]=8'd0; mem[135]=8'd4;  // C4
   mem[136]=8'd 4; mem[137]=8'd0; mem[138]=8'd0; mem[139]=8'd4;  // D4
   mem[140]=8'd16; mem[141]=8'd0; mem[142]=8'd0; mem[143]=8'd2;  // E4 八分
   mem[144]=8'd32; mem[145]=8'd0; mem[146]=8'd0; mem[147]=8'd2;  // F4 八分
   mem[148]=8'd16; mem[149]=8'd0; mem[150]=8'd0; mem[151]=8'd4;  // E4
   mem[152]=8'd 1; mem[153]=8'd0; mem[154]=8'd0; mem[155]=8'd4;  // C4
   mem[156]=8'd 4; mem[157]=8'd0; mem[158]=8'd0; mem[159]=8'd4;  // D4
   mem[160]=8'd16; mem[161]=8'd0; mem[162]=8'd0; mem[163]=8'd2;  // E4 八分
   mem[164]=8'd32; mem[165]=8'd0; mem[166]=8'd0; mem[167]=8'd2;  // F4 八分
   mem[168]=8'd16; mem[169]=8'd0; mem[170]=8'd0; mem[171]=8'd4;  // E4
   mem[172]=8'd 4; mem[173]=8'd0; mem[174]=8'd0; mem[175]=8'd4;  // D4
   mem[176]=8'd 1; mem[177]=8'd0; mem[178]=8'd0; mem[179]=8'd4;  // C4
   mem[180]=8'd 4; mem[181]=8'd0; mem[182]=8'd0; mem[183]=8'd4;  // D4
   mem[184]=8'd128; mem[185]=8'd0; mem[186]=8'd0; mem[187]=8'd8;  // G4（原谱低音 G3 超下限，改用 G4）二分
   // ---- 句 4：3 3 4 5 | 5 4 3 2 | 1 1 2 3 | 2. 1 1 ----
   mem[188]=8'd16; mem[189]=8'd0; mem[190]=8'd0; mem[191]=8'd4;  // E4
   mem[192]=8'd16; mem[193]=8'd0; mem[194]=8'd0; mem[195]=8'd4;  // E4
   mem[196]=8'd32; mem[197]=8'd0; mem[198]=8'd0; mem[199]=8'd4;  // F4
   mem[200]=8'd128; mem[201]=8'd0; mem[202]=8'd0; mem[203]=8'd4;  // G4
   mem[204]=8'd128; mem[205]=8'd0; mem[206]=8'd0; mem[207]=8'd4;  // G4
   mem[208]=8'd32; mem[209]=8'd0; mem[210]=8'd0; mem[211]=8'd4;  // F4
   mem[212]=8'd16; mem[213]=8'd0; mem[214]=8'd0; mem[215]=8'd4;  // E4
   mem[216]=8'd 4; mem[217]=8'd0; mem[218]=8'd0; mem[219]=8'd4;  // D4
   mem[220]=8'd 1; mem[221]=8'd0; mem[222]=8'd0; mem[223]=8'd4;  // C4
   mem[224]=8'd 1; mem[225]=8'd0; mem[226]=8'd0; mem[227]=8'd4;  // C4
   mem[228]=8'd 4; mem[229]=8'd0; mem[230]=8'd0; mem[231]=8'd4;  // D4
   mem[232]=8'd16; mem[233]=8'd0; mem[234]=8'd0; mem[235]=8'd4;  // E4
   mem[236]=8'd16; mem[237]=8'd0; mem[238]=8'd0; mem[239]=8'd6;  // E4 附点四分
   mem[240]=8'd 4; mem[241]=8'd0; mem[242]=8'd0; mem[243]=8'd2;  // D4 八分
   mem[244]=8'd 4; mem[245]=8'd0; mem[246]=8'd0; mem[247]=8'd8;  // D4 二分
   // 248..511 保持 0（未用槽位内容）
  end
 end
endgenerate

always @(posedge clk) begin
 if(we) mem[waddr]<=wdata;
 rdata<=mem[raddr];
end
endmodule
