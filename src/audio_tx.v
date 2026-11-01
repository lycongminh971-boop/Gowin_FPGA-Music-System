module audio_tx #(parameter I2S_MODE=0)(
 input wire clk,
 input wire rst,
 input wire signed [15:0] sample,
 output wire tick,
 output wire bck,
 output wire ws,
 output reg din
);
reg [9:0] cnt;
reg [15:0] sample_frame;
assign tick=(cnt==0);
assign ws=cnt[9];
assign bck=I2S_MODE?cnt[3]:cnt[4];
wire [4:0] i2s_bit=cnt[8:4];
always @(posedge clk) begin
 if(rst) begin 
    cnt<=0;sample_frame<=0;din<=0;
    end
 else begin
  cnt<=cnt+1'b1;
  if(cnt==1023) sample_frame<=sample;
  if(I2S_MODE) begin
   if(cnt[3:0]==0) begin
    if(i2s_bit>=1 && i2s_bit<=16) 
    din<=sample_frame[16-i2s_bit];
    else 
    din<=0;
   end
  end else if(cnt[4:0]==0) din<=sample_frame[15-cnt[8:5]];
 end
end
endmodule
