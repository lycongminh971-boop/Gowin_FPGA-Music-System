`timescale 1ns/1ps
// review_touch_tb.v —— MPR121 触摸驱动：配置、12 键位图、延迟、释放与过流保护。
// 覆盖：ready 后写入 0xa55、0xfff 位图，松手归零，overcurrent 触发 fault。
// 判据：位图须原样出现在 key 上；故障时 key 必须清零，不得卡键。
// 注意：模型 FILTER_NS 决定滤波延迟，10 ms 上限为整机节拍估值。
module review_touch_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1,enabled=1,overcurrent=0;
reg [11:0] touch=0;
tri scl,sda;pullup(scl);pullup(sda);
wire [11:0] key;
wire ready,fault,frame;
mpr121 #(.BOOT_CNT(100),.SETTLE_CNT(1000),.RETRY_CNT(1000)) dut(
 .clk(clk),.rst(rst),.scl(scl),.sda(sda),.key(key),.frame_stb(frame),.ready(ready),.fault(fault));
i2c_sensor_model model(scl,sda,enabled,1'b0,touch,16'd0,overcurrent);
time began;
initial begin
 repeat(10) @(negedge clk);rst=0;
 wait(ready);touch=12'ha55;began=$time;
 wait(key==12'ha55);
 if($time-began>10000000) $fatal(1,"modeled touch latency exceeds10ms");
 $display("modeled touch latency ns=%0d",$time-began);
 touch=0;wait(key==0);
 touch=12'hfff;wait(key==12'hfff);overcurrent=1;
 wait(fault);
 if(key!=0) $fatal(1,"fault left stuck keys");
 $display("PASS review_touch: configuration, 12-key bitmap, modeled filter latency, release, fault");
 $finish;
end
initial begin #100000000;$fatal(1,"touch timeout");end
endmodule
