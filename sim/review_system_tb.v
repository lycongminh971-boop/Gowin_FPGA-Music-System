`timescale 1ns/1ps
// review_system_tb.v —— 整机联调：双触摸传感器经声部分配送到 PCM 串行口。
// 覆盖：两路 MPR121 同时按下、key_all 合并、voice_count 计数。
// 判据：解串 16 位字须等于 u_tx.sample_frame；触摸到首字的仿真延迟小于 10 ms。
// 注意：sample_frame 与 rst 为内部探针，仅用于白盒比对。
module review_system_tb;
reg clk=0;always #10 clk=~clk;
reg reset_n=0;
reg [11:0] touch1=0,touch2=0;
tri s1,d1,s2,d2,st,dt;
pullup(s1);pullup(d1);pullup(s2);pullup(d2);pullup(st);pullup(dt);
wire bck,ws,din;
star dut(.clk(clk),.rst_n(reset_n),.key1(1'b1),
 .hp_bck(bck),.hp_ws(ws),.hp_din(din),.bt_rxd(1'b1),
 .mpr_scl(s1),.mpr_sda(d1),.mpr2_scl(s2),.mpr2_sda(d2),.vl53_scl(st),.vl53_sda(dt),
 .enc_a(1'b1),.enc_b(1'b1),.enc_sw(1'b1));
GSR GSR(.GSRI(1'b1));
defparam dut.u_mpr.SETTLE_CNT=1000;
defparam dut.u_mpr2.SETTLE_CNT=1000;
defparam dut.u_tof.PWR_CNT=100;
i2c_sensor_model m1(s1,d1,1'b1,1'b0,touch1,16'd0,1'b0);
i2c_sensor_model m2(s2,d2,1'b1,1'b0,touch2,16'd0,1'b0);
i2c_sensor_model #(.ADDRESS(7'h29),.KIND(2)) mt(st,dt,1'b1,1'b0,12'd0,16'd100,1'b0);
integer n=0,words=0;
reg [15:0] decoded=0,expected=0;
time control_start,first_audio=0;
always @(posedge bck) if(!dut.rst) begin
 if(n==0) expected=dut.u_tx.sample_frame;
 decoded={decoded[14:0],din};
 if(n==15) begin
  if(decoded!==expected) $fatal(1,"top audio serializer mismatch");
  if(decoded!=0 && first_audio==0 && control_start!=0) first_audio=$time;
  words=words+1;n=0;
 end else n=n+1;
end
initial begin
 control_start=0;#1000;reset_n=1;
 wait(dut.touch_ready && dut.touch_ready2);
 @(negedge clk);control_start=$time;touch1=1;touch2=12'h800;
 wait(first_audio!=0);
 if(first_audio-control_start>10000000) $fatal(1,"modeled end-to-end exceeds10ms");
 wait(dut.key_all==24'h800001);
 repeat(200) @(negedge clk);
 if(dut.voice_count!=2) $fatal(1,"two sensors failed voice allocation");
 $display("PASS review_system: dual MPR -> voice -> PCM -> serial; modeled latency ns=%0d",first_audio-control_start);
 $finish;
end
initial begin #100000000;$fatal(1,"system timeout");end
endmodule
