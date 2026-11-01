`timescale 1ns/1ps
// rgb_scope 显示验证：480x272 有效区、531x292 帧时序、每行 480 像素。
// 依次截取浏览态、调整态、指引中、自动演奏中的画面，并检查距离无效时显示 '----'。
module review_lcd_tb;
 reg clk=0; always #10 clk=~clk;
 reg rst=1;
 reg [9:0] cnt=0;
 reg signed [15:0] signal_sample=0;
 always @(posedge clk) begin
  cnt<=cnt+1'b1;
  if(cnt==0) signal_sample<=signal_sample+16'd1024;
 end
 reg [2:0] item=3'd0;
 reg [1:0] bt_song=2'd0;
 reg [3:0] bt_ready=4'd0;
 reg [2:0] bt_state=3'd0;
 reg bt_link=0,bt_guide=0,bt_auto=0;
 reg [8:0] bt_done=9'd0,bt_total=9'd0;
 reg [23:0] g_targets=24'd0;
 reg g_valid=0;
 reg [8:0] g_hit=9'd42,g_miss=9'd5;
 reg g_urgent=0;
 reg select_mode=0,test_mode=0,delay_on=0;
 reg [1:0] timbre=2'd1,vibrato=2'd0;
 reg signed [5:0] bend=6'sd0;
 reg [15:0] distance=16'd300;
 wire pclk,bl,hs,vs,de;
 wire [5:0] r,g,b;
 rgb_scope #(.INSTRUMENT_PRESETS(1)) dut(
  .clk(clk),.rst(rst),.sample_valid(cnt==0),.sample(signal_sample),
  .keys(24'h800001),.voices(6'd2),.volume(16'd32768),.distance(distance),
  .status(8'h33),.item(item),.select_mode(select_mode),.test_mode(test_mode),
  .bt_song(bt_song),.bt_ready(bt_ready),.bt_state(bt_state),.bt_link(bt_link),
  .bt_guide(bt_guide),.bt_auto(bt_auto),.bt_done(bt_done),.bt_total(bt_total),
  .g_targets(g_targets),.g_valid(g_valid),
  .g_hit(g_hit),.g_miss(g_miss),.g_urgent(g_urgent),
  .vibrato(vibrato),.timbre(timbre),.delay_on(delay_on),.bend(bend),
  .pclk(pclk),.backlight(bl),.hs(hs),.vs(vs),.de(de),.red(r),.green(g),.blue(b));
 // 层次探针：距离字符直接读 DUT 内部
 wire [7:0] p_dist_ch3 = dut.dist_ch3;
 wire [7:0] p_dist_ch0 = dut.dist_ch0;
 localparam integer HT_EXPECT=531;
 localparam integer VT_EXPECT=292;
 integer pixels=0,active_pixels=0,lines=0,frames=0,line_active=0;
 integer img0,img1,img2,img3;
 reg started=0,prev_de=0,prev_vs=1;
 integer sync_x=0,sync_y=0;
 reg prev_hs=1,check_prev_de=0,check_prev_vs=1,first_active=1;
 always @(posedge pclk) if(!rst) begin
  if(check_prev_vs && !vs) begin sync_y=0; first_active=1; end
  else if(prev_hs && !hs) sync_y=sync_y+1;
  if(prev_hs && !hs) sync_x=0;
  else sync_x=sync_x+1;
  if(de && !check_prev_de && sync_x!=43) $fatal(1,"HS-to-DE interval=%0d expected 43",sync_x);
  if(de && first_active) begin
   if(sync_y!=12) $fatal(1,"VS-to-first-DE interval=%0d expected 12",sync_y);
   first_active=0;
  end
  prev_hs=hs; check_prev_de=de; check_prev_vs=vs;
 end
 integer capture_frame=2;
 always @(posedge pclk) if(!rst) begin
  if(de && !prev_de) begin
   if(frames>=1 && lines!=0 && line_active!=480) $fatal(1,"row %0d length %0d",lines,line_active);
   line_active=0;
  end
  if(de) line_active=line_active+1;
  if(prev_de && !de) lines=lines+1;
  if(prev_vs && !vs) begin
   if(started) begin
    if(frames>=1 && pixels!=HT_EXPECT*VT_EXPECT) $fatal(1,"frame clocks %0d",pixels);
    if(frames>=1 && active_pixels!=480*272) $fatal(1,"active pixels %0d",active_pixels);
    if(frames>=1 && lines!=272) $fatal(1,"rows %0d",lines);
    frames=frames+1;
   end
   started=1; pixels=0; active_pixels=0; lines=0; line_active=0;
  end
  if(started) begin pixels=pixels+1; if(de) active_pixels=active_pixels+1; end
  if(frames==capture_frame && de) begin
   if(capture_frame==2)      $fdisplay(img0,"%0d %0d %0d",r*4,g*4,b*4);
   else if(capture_frame==6) $fdisplay(img1,"%0d %0d %0d",r*4,g*4,b*4);
   else if(capture_frame==10) $fdisplay(img2,"%0d %0d %0d",r*4,g*4,b*4);
   else if(capture_frame==14) $fdisplay(img3,"%0d %0d %0d",r*4,g*4,b*4);
  end
  if(bl!==0) $fatal(1,"standalone rgb_scope must keep backlight off");
  if(de && ^{r,g,b}===1'bx) $fatal(1,"unknown visible pixel");
  prev_vs=vs; prev_de=de;
 end
 initial begin
  img0=$fopen("review_screen_browse.ppm","w");
  $fdisplay(img0,"P3\n480 272\n255");
  repeat(10) @(negedge clk); rst=0;
  // 阶段 1：浏览态，音色 SQUARE（最长名字），有波形
  timbre=2'd2; item=3'd0; select_mode=0; bend=6'sd0;
  wait(frames==3);
  if(!dut.have_frame) $fatal(1,"waveform buffer never swapped");
  $fclose(img0);
  // 阶段 2：调整态，BEND -12，颤音 3，延时开，距离无效
  item=3'd1; select_mode=1; bend=-6'sd12; vibrato=2'd3; delay_on=1; test_mode=0;
  distance=16'd0;
  $display("  ok browse frame rendered (SQUARE)");
  wait(frames==5);
  if(p_dist_ch3!=8'h2D || p_dist_ch0!=8'h2D)
   $fatal(1,"invalid distance must show ----, got %0d/%0d",p_dist_ch3,p_dist_ch0);
  $display("  ok invalid distance shows ----");
  capture_frame=6;
  img1=$fopen("review_screen_edit.ppm","w");
  $fdisplay(img1,"P3\n480 272\n255");
  wait(frames==7);
  $fclose(img1);
  $display("  ok edit frame rendered (BEND -12ST, DELAY on)");
  // 阶段 3：指引中，目标键 key7，带命中/漏音统计
  item=3'd3; select_mode=0; bt_song=2'd0; bt_ready=4'b0001; bt_guide=1;
  bt_done=9'd12; bt_total=9'd48; g_targets=24'h000080; g_valid=1;
  capture_frame=10;
  img2=$fopen("review_screen_guide.ppm","w");
  $fdisplay(img2,"P3\n480 272\n255");
  wait(frames==11);
  $fclose(img2);
  $display("  ok guide frame rendered (G012/048, target key lit)");
  // 阶段 4：自动演奏中，前缀应为 A，目标键熄灭
  item=3'd0; bt_auto=1; g_valid=0;
  bt_done=9'd20; bt_total=9'd62;
  capture_frame=14;
  img3=$fopen("review_screen_auto.ppm","w");
  $fdisplay(img3,"P3\n480 272\n255");
  wait(frames==15);
  $fclose(img3);
  $display("  ok auto frame rendered (A020/062)");
  $display("PASS review_lcd: 480x272 active, 531x292 totals, 480 px/row, ---- on invalid distance, 4 screenshots");
  $finish;
 end
 initial begin #400000000; $fatal(1,"LCD timeout"); end
endmodule
