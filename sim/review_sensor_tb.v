`timescale 1ns/1ps
// review_sensor_tb.v —— VL53L0X 测距驱动：初始化序列、SPAD 过滤、距离与状态。
// 覆盖：KIND=2 模型下读到 321 mm，rs_ok/dev_found/rs_code 与停止变量保持。
// 判据：SPAD 图过滤结果须为 0x00000001f000；掉线后不得发布旧距离。
// 注意：直接读写模型 mem，属白盒建模，不代表物理光学指标。
module review_sensor_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1,enabled=1;
tri scl,sda;pullup(scl);pullup(sda);
wire [15:0] distance;
wire valid,ok,found;
wire [3:0] code;
vl53l0x #(.PWR_CNT(100),.POLL_TO(500000)) dut(
 .clk(clk),.rst(rst),.dist_mm(distance),.dist_vld(valid),.rs_ok(ok),.rs_code(code),.dev_found(found),
 .scl(scl),.sda(sda));
i2c_sensor_model #(.ADDRESS(7'h29),.KIND(2)) model(
 scl,sda,enabled,1'b0,12'd0,16'd321,1'b0);
integer i;
initial begin
 #1;
 for(i=0;i<6;i=i+1) model.mem[8'hb0+i]=8'hff;
 model.mem[8'h91]=8'ha7;
 repeat(10) @(negedge clk);rst=0;
 wait(valid);#1;
 if(distance!=321 || !ok || !found || code!=11) $fatal(1,"ToF read/status failed");
 if(dut.stop_value!=8'ha7 || model.mem[8'h91]!=8'ha7) $fatal(1,"stop variable not preserved");
 if({model.mem[8'hb5],model.mem[8'hb4],model.mem[8'hb3],model.mem[8'hb2],model.mem[8'hb1],model.mem[8'hb0]}!==48'h00000001f000)
  $fatal(1,"SPAD map filtering failed");
 if(model.mem[8'h01]!=8'he8 || model.mem[8'h00]!=2) $fatal(1,"continuous setup missing");
 enabled=0;
 wait(!found);
 repeat(10000) @(negedge clk);
 if(ok || valid) $fatal(1,"failed transaction published stale distance");
 $display("PASS review_sensor: full sequence, SPAD filtering, stop variable, status, distance, disconnect");
 $finish;
end
initial begin #100000000;$fatal(1,"sensor timeout");end
endmodule
