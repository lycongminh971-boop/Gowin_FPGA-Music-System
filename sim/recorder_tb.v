`timescale 1ns/1ps
// recorder_tb —— 验证 recorder 的事件落盘格式与录音边界。
// 覆盖空闲/就绪、四字节顺序、长音切段、复音合并、停止时落盘。
// 用人工 t16 脉冲计时，避免依赖 beat_gen 的计数器相位。
module recorder_tb;
reg clk=0;
always #10 clk=~clk;              // 50MHz
reg rst=1;
reg [23:0] keys=0;
reg rec_start=0,rec_stop=0,t16=0;

wire we,rec_busy,rec_ready,rec_full;
wire [10:0] waddr,raddr;
wire [7:0]  wdata,rdata;
wire [11:0] rec_bytes;
assign raddr = 11'd0;

recorder u_rec(.clk(clk),.rst(rst),.keys(keys),
 .rec_start(rec_start),.rec_stop(rec_stop),.t16_tick(t16),
 .we(we),.waddr(waddr),.wdata(wdata),
 .rec_busy(rec_busy),.rec_ready(rec_ready),.rec_full(rec_full),.rec_bytes(rec_bytes));
song_ram #(.WITH_INIT(0)) u_ram(.clk(clk),.we(we),.waddr(waddr),.wdata(wdata),
 .raddr(raddr),.rdata(rdata));

integer errors=0;
task chk;
 input [255:0] name;
 input [31:0]  got;
 input [31:0]  exp;
 begin
  if(got!==exp) begin
   errors=errors+1;
   $display("FAIL  %0s : got %0d  exp %0d",name,got,exp);
  end else $display("ok    %0s = %0d",name,got);
 end
endtask

// t16 用 negedge 设值，保证高电平覆盖一个 posedge；间隔 3 拍避开 R_WR 写盘盲区。
task tick_pulse;
 begin
  @(negedge clk); t16=1'b1;
  @(negedge clk); t16=1'b0;
  repeat(3) @(negedge clk);
 end
endtask

// 按住 k 打 n 个 tick；先等 2 拍进入 R_HOLD，松手后等 8 拍落盘。
task play;
 input [4:0]   k;
 input integer n;
 integer i;
 begin
  @(negedge clk); keys = 24'd1<<k;
  repeat(2) @(negedge clk);
  for(i=0;i<n;i=i+1) tick_pulse;
  @(negedge clk); keys = 24'd0;
  repeat(8) @(negedge clk);
 end
endtask

task do_start;
 begin @(negedge clk); rec_start=1'b1; @(negedge clk); rec_start=1'b0; repeat(2) @(negedge clk); end
endtask
task do_stop;
 begin @(negedge clk); rec_stop=1'b1; @(negedge clk); rec_stop=1'b0; repeat(10) @(negedge clk); end
endtask

integer i;
initial begin
 $dumpfile("recorder_tb.vcd");
 $dumpvars(0,recorder_tb);
 repeat(5) @(negedge clk);
 rst=0;
 repeat(5) @(negedge clk);

 // T0 复位后空闲
 $display("--- T0 复位后空闲 ---");
 chk("T0 busy",  rec_busy,  0);
 chk("T0 ready", rec_ready, 0);
 chk("T0 bytes", rec_bytes, 0);

 // T1 三个音的顺序与时值
 $display("--- T1 三个音的顺序与时值 ---");
 do_start;
 chk("T1 录音中", rec_busy, 1);
 play(0,  3);
 play(7,  2);
 play(23, 1);
 do_stop;
 chk("T1 bytes",  rec_bytes, 12);          // 3 事件 x 4 字节
 chk("T1 ready",  rec_ready, 1);
 chk("T1 busy",   rec_busy,  0);
 // 事件 0：key0 -> LO=1<<0=1, MID=0, HI=0, DUR=3
 chk("T1 e0.lo",  u_ram.mem[0], 1);
 chk("T1 e0.mid", u_ram.mem[1], 0);
 chk("T1 e0.hi",  u_ram.mem[2], 0);
 chk("T1 e0.dur", u_ram.mem[3], 3);
 // 事件 1：key7 -> LO=1<<7=128
 chk("T1 e1.lo",  u_ram.mem[4], 128);
 chk("T1 e1.mid", u_ram.mem[5], 0);
 chk("T1 e1.hi",  u_ram.mem[6], 0);
 chk("T1 e1.dur", u_ram.mem[7], 2);
 // 事件 2：key23 -> HI=1<<(23-16)=0x80
 chk("T1 e2.lo",  u_ram.mem[8], 0);
 chk("T1 e2.mid", u_ram.mem[9], 0);
 chk("T1 e2.hi",  u_ram.mem[10], 128);
 chk("T1 e2.dur", u_ram.mem[11], 1);

 // T2 长音切段
 $display("--- T2 长音超过 127 被切段 ---");
 do_start;
 play(3, 130);
 do_stop;
 // 130 个 tick：第 128 个 tick 时 dur 已满 127 → 落一个 127，重新计时
 //   剩下 tick129=1、tick130=2 → 松手落一个 2
 chk("T2 bytes",  rec_bytes, 8);           // 2 事件 x 4 字节
 chk("T2 e0.lo",  u_ram.mem[0], 8);        // key3 -> LO=1<<3=8
 chk("T2 e0.hi",  u_ram.mem[2], 0);
 chk("T2 e0.dur", u_ram.mem[3], 127);
 chk("T2 e1.lo",  u_ram.mem[4], 8);
 chk("T2 e1.dur", u_ram.mem[7], 2);

 // T3 复音合并
 $display("--- T3 复音：后按下的键并入同一事件 ---");
 do_start;
 @(negedge clk); keys = 24'd1<<0;          // 按下 A(key0)
 repeat(2) @(negedge clk);
 for(i=0;i<3;i=i+1) tick_pulse;            // A 单独 3 拍
 @(negedge clk); keys = (24'd1<<0)|(24'd1<<5); // 又按下 B(key5)，A 还按着
 for(i=0;i<2;i=i+1) tick_pulse;            // 2 拍：仍算在 A 头上
 @(negedge clk); keys = 24'd1<<5;          // 松开 A，B 还按着
 // B 已并入 cur_keys，松开 A 不会结束事件，事件继续到 B 松开。
 repeat(5) @(negedge clk);
 for(i=0;i<3;i=i+1) tick_pulse;            // B 3 拍
 @(negedge clk); keys = 24'd0;
 repeat(4) @(negedge clk);
 do_stop;
 chk("T3 bytes",  rec_bytes, 4);           // 只落 1 个事件。
 chk("T3 e0.lo",  u_ram.mem[0], 33);       // key0|key5 = 1|32 = 33，一个事件里两个键
 chk("T3 e0.mid", u_ram.mem[1], 0);
 chk("T3 e0.hi",  u_ram.mem[2], 0);
 chk("T3 e0.dur", u_ram.mem[3], 8);        // 从 A 按下到 B 松开，共 3+2+3=8 拍

 // T4 停止时落盘
 $display("--- T4 rec_stop 时手上的音也落盘 ---");
 do_start;
 @(negedge clk); keys = 24'd1<<9;
 repeat(2) @(negedge clk);
 for(i=0;i<4;i=i+1) tick_pulse;
 // 不松手，直接停
 do_stop;
 chk("T4 bytes",  rec_bytes, 4);
 chk("T4 ready",  rec_ready, 1);
 chk("T4 busy",   rec_busy,  0);
 chk("T4 e0.lo",  u_ram.mem[0], 0);        // key9 -> MID=1<<(9-8)=2
 chk("T4 e0.mid", u_ram.mem[1], 2);
 chk("T4 e0.hi",  u_ram.mem[2], 0);
 chk("T4 e0.dur", u_ram.mem[3], 4);
 @(negedge clk); keys = 24'd0;
 repeat(3) @(negedge clk);

 $display("");
 if(errors==0) $display("==== recorder_tb PASS (all checks) ====");
 else          $display("==== recorder_tb FAIL : %0d error(s) ====",errors);
 $finish;
end
endmodule
