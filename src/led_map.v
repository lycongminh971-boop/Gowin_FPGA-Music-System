module led_map #(
 parameter integer NKEY     = 24,
 parameter integer SPLIT    = 12,   // 前 SPLIT 个键占低位 2*SPLIT 位（=24 位）
 parameter integer SWAP_DIE = 0     // 0 = 偶数位 guide / 奇数位 press；1 = 反过来
)(
 input  wire [NKEY-1:0]   press,    // 按键按下显示
 input  wire [NKEY-1:0]   guide,    // 引导模式指示
 output wire [2*NKEY-1:0] bits      // 送给 tlc59282_chain 的 48 位
);
localparam integer LOWBITS = 2*SPLIT;   // 24

genvar k;
generate
 // ---- 低位组：key0~key11 → LED1~LED12，占 bits[23:0] ----
 for(k=0;k<SPLIT;k=k+1) begin:g_low
  if(SWAP_DIE) begin:g_low_sw
   assign bits[2*k]   = press[k];
   assign bits[2*k+1] = guide[k];
  end else begin:g_low_nm
   assign bits[2*k]   = guide[k];
   assign bits[2*k+1] = press[k];
  end
 end
 // ---- 高位组：key12~key23 → LED13~LED24，占 bits[47:24] ----
 for(k=SPLIT;k<NKEY;k=k+1) begin:g_high
  if(SWAP_DIE) begin:g_high_sw
   assign bits[LOWBITS + 2*(k-SPLIT)]   = press[k];
   assign bits[LOWBITS + 2*(k-SPLIT)+1] = guide[k];
  end else begin:g_high_nm
   assign bits[LOWBITS + 2*(k-SPLIT)]   = guide[k];
   assign bits[LOWBITS + 2*(k-SPLIT)+1] = press[k];
  end
 end
endgenerate
endmodule
