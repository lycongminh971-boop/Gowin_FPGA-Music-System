module gw_gao(
    \u_eng/dout[15] ,
    \u_eng/dout[14] ,
    \u_eng/dout[13] ,
    \u_eng/dout[12] ,
    \u_eng/dout[11] ,
    \u_eng/dout[10] ,
    \u_eng/dout[9] ,
    \u_eng/dout[8] ,
    \u_eng/dout[7] ,
    \u_eng/dout[6] ,
    \u_eng/dout[5] ,
    \u_eng/dout[4] ,
    \u_eng/dout[3] ,
    \u_eng/dout[2] ,
    \u_eng/dout[1] ,
    \u_eng/dout[0] ,
    \frame_cnt[15] ,
    \frame_cnt[14] ,
    \frame_cnt[13] ,
    \frame_cnt[12] ,
    \frame_cnt[11] ,
    \frame_cnt[10] ,
    \frame_cnt[9] ,
    \frame_cnt[8] ,
    \frame_cnt[7] ,
    \frame_cnt[6] ,
    \frame_cnt[5] ,
    \frame_cnt[4] ,
    \frame_cnt[3] ,
    \frame_cnt[2] ,
    \frame_cnt[1] ,
    \frame_cnt[0] ,
    \u_eng/gate[0] ,
    tick,
    \kb_gate[0] ,
    \u_eng/sample_valid ,
    \touch_key[0] ,
    tms_pad_i,
    tck_pad_i,
    tdi_pad_i,
    tdo_pad_o
);

input \u_eng/dout[15] ;
input \u_eng/dout[14] ;
input \u_eng/dout[13] ;
input \u_eng/dout[12] ;
input \u_eng/dout[11] ;
input \u_eng/dout[10] ;
input \u_eng/dout[9] ;
input \u_eng/dout[8] ;
input \u_eng/dout[7] ;
input \u_eng/dout[6] ;
input \u_eng/dout[5] ;
input \u_eng/dout[4] ;
input \u_eng/dout[3] ;
input \u_eng/dout[2] ;
input \u_eng/dout[1] ;
input \u_eng/dout[0] ;
input \frame_cnt[15] ;
input \frame_cnt[14] ;
input \frame_cnt[13] ;
input \frame_cnt[12] ;
input \frame_cnt[11] ;
input \frame_cnt[10] ;
input \frame_cnt[9] ;
input \frame_cnt[8] ;
input \frame_cnt[7] ;
input \frame_cnt[6] ;
input \frame_cnt[5] ;
input \frame_cnt[4] ;
input \frame_cnt[3] ;
input \frame_cnt[2] ;
input \frame_cnt[1] ;
input \frame_cnt[0] ;
input \u_eng/gate[0] ;
input tick;
input \kb_gate[0] ;
input \u_eng/sample_valid ;
input \touch_key[0] ;
input tms_pad_i;
input tck_pad_i;
input tdi_pad_i;
output tdo_pad_o;

wire \u_eng/dout[15] ;
wire \u_eng/dout[14] ;
wire \u_eng/dout[13] ;
wire \u_eng/dout[12] ;
wire \u_eng/dout[11] ;
wire \u_eng/dout[10] ;
wire \u_eng/dout[9] ;
wire \u_eng/dout[8] ;
wire \u_eng/dout[7] ;
wire \u_eng/dout[6] ;
wire \u_eng/dout[5] ;
wire \u_eng/dout[4] ;
wire \u_eng/dout[3] ;
wire \u_eng/dout[2] ;
wire \u_eng/dout[1] ;
wire \u_eng/dout[0] ;
wire \frame_cnt[15] ;
wire \frame_cnt[14] ;
wire \frame_cnt[13] ;
wire \frame_cnt[12] ;
wire \frame_cnt[11] ;
wire \frame_cnt[10] ;
wire \frame_cnt[9] ;
wire \frame_cnt[8] ;
wire \frame_cnt[7] ;
wire \frame_cnt[6] ;
wire \frame_cnt[5] ;
wire \frame_cnt[4] ;
wire \frame_cnt[3] ;
wire \frame_cnt[2] ;
wire \frame_cnt[1] ;
wire \frame_cnt[0] ;
wire \u_eng/gate[0] ;
wire tick;
wire \kb_gate[0] ;
wire \u_eng/sample_valid ;
wire \touch_key[0] ;
wire tms_pad_i;
wire tck_pad_i;
wire tdi_pad_i;
wire tdo_pad_o;
wire tms_i_c;
wire tck_i_c;
wire tdi_i_c;
wire tdo_o_c;
wire [9:0] control0;
wire [9:0] control1;
wire gao_jtag_tck;
wire gao_jtag_reset;
wire run_test_idle_er1;
wire run_test_idle_er2;
wire shift_dr_capture_dr;
wire update_dr;
wire pause_dr;
wire enable_er1;
wire enable_er2;
wire gao_jtag_tdi;
wire tdo_er1;

IBUF tms_ibuf (
    .I(tms_pad_i),
    .O(tms_i_c)
);

IBUF tck_ibuf (
    .I(tck_pad_i),
    .O(tck_i_c)
);

IBUF tdi_ibuf (
    .I(tdi_pad_i),
    .O(tdi_i_c)
);

OBUF tdo_obuf (
    .I(tdo_o_c),
    .O(tdo_pad_o)
);

GW_JTAG  u_gw_jtag(
    .tms_pad_i(tms_i_c),
    .tck_pad_i(tck_i_c),
    .tdi_pad_i(tdi_i_c),
    .tdo_pad_o(tdo_o_c),
    .tck_o(gao_jtag_tck),
    .test_logic_reset_o(gao_jtag_reset),
    .run_test_idle_er1_o(run_test_idle_er1),
    .run_test_idle_er2_o(run_test_idle_er2),
    .shift_dr_capture_dr_o(shift_dr_capture_dr),
    .update_dr_o(update_dr),
    .pause_dr_o(pause_dr),
    .enable_er1_o(enable_er1),
    .enable_er2_o(enable_er2),
    .tdi_o(gao_jtag_tdi),
    .tdo_er1_i(tdo_er1),
    .tdo_er2_i(1'b0)
);

gw_con_top  u_icon_top(
    .tck_i(gao_jtag_tck),
    .tdi_i(gao_jtag_tdi),
    .tdo_o(tdo_er1),
    .rst_i(gao_jtag_reset),
    .control0(control0[9:0]),
    .control1(control1[9:0]),
    .enable_i(enable_er1),
    .shift_dr_capture_dr_i(shift_dr_capture_dr),
    .update_dr_i(update_dr)
);

ao_top_0  u_la0_top(
    .control(control0[9:0]),
    .trig0_i(\u_eng/gate[0] ),
    .data_i({\u_eng/dout[15] ,\u_eng/dout[14] ,\u_eng/dout[13] ,\u_eng/dout[12] ,\u_eng/dout[11] ,\u_eng/dout[10] ,\u_eng/dout[9] ,\u_eng/dout[8] ,\u_eng/dout[7] ,\u_eng/dout[6] ,\u_eng/dout[5] ,\u_eng/dout[4] ,\u_eng/dout[3] ,\u_eng/dout[2] ,\u_eng/dout[1] ,\u_eng/dout[0] ,\frame_cnt[15] ,\frame_cnt[14] ,\frame_cnt[13] ,\frame_cnt[12] ,\frame_cnt[11] ,\frame_cnt[10] ,\frame_cnt[9] ,\frame_cnt[8] ,\frame_cnt[7] ,\frame_cnt[6] ,\frame_cnt[5] ,\frame_cnt[4] ,\frame_cnt[3] ,\frame_cnt[2] ,\frame_cnt[1] ,\frame_cnt[0] }),
    .clk_i(tick)
);

ao_top_1  u_la1_top(
    .control(control1[9:0]),
    .trig0_i(\touch_key[0] ),
    .data_i({\u_eng/dout[15] ,\u_eng/dout[14] ,\u_eng/dout[13] ,\u_eng/dout[12] ,\u_eng/dout[11] ,\u_eng/dout[10] ,\u_eng/dout[9] ,\u_eng/dout[8] ,\u_eng/dout[7] ,\u_eng/dout[6] ,\u_eng/dout[5] ,\u_eng/dout[4] ,\u_eng/dout[3] ,\u_eng/dout[2] ,\u_eng/dout[1] ,\u_eng/dout[0] ,\kb_gate[0] ,\u_eng/sample_valid ,\touch_key[0] }),
    .clk_i(tick)
);

endmodule
