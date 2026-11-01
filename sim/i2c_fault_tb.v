`timescale 1ns/1ps
module i2c_fault_tb;
reg clk=0;always #10 clk=~clk;
reg rst=1,go=0,rd=0,enabled=1,nack=0,stuck=0;
reg [7:0] idx=8'h20,wdata=8'ha5;
wire [7:0] rdata;
wire rvld,busy,done,err;
tri scl,sda;pullup(scl);pullup(sda);
assign scl=stuck?1'b0:1'bz;
i2c_master #(.SCL_HZ(100000),.TIMEOUT_CYCLES(100000)) dut(
 .clk(clk),.rst(rst),.go(go),.rd(rd),.dev(7'h5a),.idx(idx),.wdata(wdata),
 .nbytes(5'd0),.rdata(rdata),.rvld(rvld),.busy(busy),.done(done),.ackerr(err),.scl(scl),.sda(sda));
i2c_sensor_model model(scl,sda,enabled,nack,12'd0,16'd0,1'b0);
task transaction;
 begin @(negedge clk);go=1;@(negedge clk);go=0;wait(done);#100;end
endtask
initial begin
 #1000;rst=0;
 transaction;
 if(err || model.mem[8'h20]!=8'ha5) $fatal(1,"normal write failed");
 nack=1;transaction;
 if(!err) $fatal(1,"final write data NACK ignored");
 nack=0;enabled=0;transaction;
 if(!err) $fatal(1,"address NACK ignored");
 enabled=1;stuck=1;transaction;
 if(!err || busy || dut.scl_oen || dut.sda_oen) $fatal(1,"timeout did not release bus");
 stuck=0;#10000;transaction;
 if(err) $fatal(1,"failed to recover after released SCL");
 $display("PASS I2C write ACK/NACK, disconnect, stretch timeout, recovery");$finish;
end
initial begin #10000000;$fatal(1,"fault test timeout");end
endmodule
