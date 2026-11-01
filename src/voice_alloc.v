module voice_alloc #(parameter NK=24, parameter NV=32)(
 input wire clk,rst, input wire [NK-1:0] key, input wire [NV-1:0] active,
 output reg [7*NV-1:0] v_pitch, output reg [NV-1:0] v_gate,
 output reg [NV-1:0] retrigger,

 output reg [NK-1:0] sounding
);
reg [NK-1:0] previous,pending;
reg [4:0] owner[0:NV-1];
reg [$clog2(NV)-1:0] next_slot;
reg [$clog2(NV)-1:0] selected_slot;
reg [4:0] selected_key;
reg dispatch;
integer i,event_key,slot,release_slot;
wire [NK-1:0] rising=key & ~previous;
always @* begin
 event_key=-1;slot=-1;release_slot=-1;
 for(i=NK-1;i>=0;i=i-1) if(pending[i] && key[i]) event_key=i;
 for(i=NV-1;i>=0;i=i-1) begin
  if(!v_gate[i]) release_slot=i;
  if(!active[i] && !v_gate[i] && !retrigger[i]) slot=i;
 end
 if(slot<0) slot=(release_slot>=0)?release_slot:next_slot;
end
integer n;
always @(posedge clk) begin
 if(rst) begin
  previous<=0;pending<=0;v_gate<=0;v_pitch<=0;retrigger<=0;next_slot<=0;dispatch<=0;selected_slot<=0;selected_key<=0;
  sounding<=0;
  for(n=0;n<NV;n=n+1) owner[n]<=0;
 end else begin
  previous<=key;pending<=(pending | rising) & key;retrigger<=0;
  for(n=0;n<NV;n=n+1) if(!key[owner[n]]) v_gate[n]<=0;
  if(dispatch) begin
   dispatch<=0;
   if(key[selected_key]) begin
    owner[selected_slot]<=selected_key;
    v_pitch[7*selected_slot +: 7]<=(selected_key<12)?{2'b00,selected_key}:(7'd4+selected_key);
    v_gate[selected_slot]<=1;retrigger[selected_slot]<=1;
    next_slot<=(selected_slot==NV-1)?0:selected_slot+1'b1;
   end
  end else if(event_key>=0) begin
   pending[event_key]<=0;selected_key<=event_key;selected_slot<=slot;dispatch<=1;
  end

  sounding<=0;
  for(n=0;n<NV;n=n+1)
   if(v_gate[n] && (owner[n] < NK)) sounding[owner[n]]<=1'b1;
 end
end
endmodule
