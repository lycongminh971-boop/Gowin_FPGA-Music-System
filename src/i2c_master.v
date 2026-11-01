module i2c_master #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 50_000,
    parameter integer TIMEOUT_CYCLES = CLK_HZ/50
)(
    input  wire        clk,
    input  wire        rst,       // 高有效
    // ---- 事务控制 ----
    input  wire        go,        // 1 拍脉冲，启动一次事务（busy=1 期间请勿再发）
    input  wire        rd,        // 1 = 读事务，0 = 写事务
    input  wire [6:0]  dev,       // 7 位从机地址（VL53L0X = 7'h29）
    input  wire [7:0]  idx,       // 8 位寄存器索引
    input  wire [7:0]  wdata,     // 写数据（rd=1 时忽略）
    input  wire [4:0]  nbytes,    // 读字节数-1（0 = 读 1 个字节）
    // ---- 结果 ----
    output reg  [7:0]  rdata = 8'd0,     // 每读完一个字节更新
    output reg         rvld  = 1'b0,     // 每读完一个字节给 1 拍脉冲
    output reg         busy  = 1'b0,     // 事务进行中
    output reg         done  = 1'b0,     // 事务结束 1 拍脉冲
    output reg         ackerr= 1'b0,     // 任一 ACK 失败（地址无应答 / 数据被 NACK）
    // ---- 物理层 ----
    inout  wire        scl,
    inout  wire        sda
);

// ---------------- 分频常数 ----------------
localparam integer Q = CLK_HZ / (4*SCL_HZ);     // 每个相位的 clk 数（50M/50k → 250）

// ---------------- 状态编码 ----------------
localparam [3:0] S_IDLE  = 4'd0,   // 等 go
                 S_START = 4'd1,   // 发 START
                 S_ADDR  = 4'd2,   // 发 addr+W（8 bit）
                 S_ACK1  = 4'd3,   // 收地址的 ACK
                 S_IDX   = 4'd4,   // 发寄存器索引（8 bit）
                 S_ACK2  = 4'd5,   // 收索引的 ACK
                 S_REST  = 4'd6,   // 发重复起始 Sr
                 S_ADDRR = 4'd7,   // 发 addr+R（8 bit）
                 S_ACK3  = 4'd8,   // 收地址的 ACK
                 S_RBYTE = 4'd9,   // 收 1 个数据字节（8 bit）
                 S_MACK  = 4'd10,  // 主机回 ACK/NACK
                 S_WDATA = 4'd11,  // 发写数据（8 bit）
                 S_ACK4  = 4'd12,  // 收写数据的 ACK
                 S_STOP  = 4'd13;  // 发 STOP

reg [3:0]  st    = S_IDLE;
reg [1:0]  ph    = 2'd0;   // 相位 0..3
reg [15:0] qc    = 16'd0;  // 相位内计数
reg [3:0]  bc    = 4'd0;   // 字节内位数 0..7
reg [7:0]  sh    = 8'd0;   // 发送移位 / 接收移位
reg [7:0]  nb    = 8'd0;   // 剩余待读字节数
reg [6:0] dev_r;
reg [7:0] idx_r, wdata_r;
reg [4:0] nbytes_r;
reg [31:0] timeout_count;
wire timed_out = busy && (timeout_count >= TIMEOUT_CYCLES-1);
always @(posedge clk) begin
    if(rst || !busy) timeout_count <= 0;
    else timeout_count <= timeout_count + 1'b1;
end
reg        rd_r  = 1'b0;   // 事务方向锁存

// ---------------- 相位计数器（带时钟拉伸冻结） ----------------
reg  scl_oen = 1'b0;                    // 1 = 拉低，0 = 释放（高阻）
reg  sda_oen = 1'b0;
(* syn_preserve=1 *) reg [1:0] scl_sync=2'b11, sda_sync=2'b11;
always @(posedge clk) begin
 if(rst) begin 
    scl_sync<=2'b11;sda_sync<=2'b11;
    end
 else begin 
    scl_sync<={scl_sync[0],scl};sda_sync<={sda_sync[0],sda};
    end
end
wire scl_i=scl_sync[1];
wire sda_i=sda_sync[1];

wire stretch = (~scl_oen) & (~scl_i);   // 我们放了高但线上还是低 → 从机在拉伸

wire [15:0] qmax = Q[15:0] - 16'd1;
wire ph_end  = (qc == qmax);

always @(posedge clk) begin
    if (rst || st == S_IDLE) begin
        qc <= 16'd0;
        ph <= 2'd0;
    end
    else if (stretch) begin
        qc <= qc;                        // 冻结，等从机放开 SCL
    end
    else if (ph_end) begin
        qc <= 16'd0;
        ph <= ph + 2'd1;                 // 2 位自然回绕 3→0
    end
    else begin
        qc <= qc + 16'd1;
    end
end

wire slot_done = ph_end & (ph == 2'd3) & (~stretch);   // 一个 bit 槽走完
wire smp_tick  = ph_end & (ph == 2'd2) & (~stretch);   // 读方向的采样点

// ---------------- 本槽类型 ----------------
wire is_start = (st == S_START) | (st == S_REST);
wire is_stop  = (st == S_STOP);
wire is_rx    = (st == S_ACK1) | (st == S_ACK2) | (st == S_ACK3) | (st == S_ACK4) | (st == S_RBYTE);

// ---------------- 发送位选择 ----------------
reg txb;
always @(*) begin
    case (st)
        S_ADDR, S_ADDRR, S_IDX, S_WDATA : txb = sh[7];       // 统一从 MSB 出
        S_MACK                          : txb = (nb == 8'd0); // 最后一字节回 NACK(高)
        default                         : txb = 1'b1;
    endcase
end

reg scl_oen_c, sda_oen_c;
always @(*) begin
    if(st == S_IDLE) begin
        scl_oen_c=0;sda_oen_c=0;
    end
    else if (is_start) begin
        scl_oen_c = (ph == 2'd3);
        sda_oen_c = (ph >= 2'd2);
    end
    else if (is_stop) begin
        scl_oen_c = (ph == 2'd0);
        sda_oen_c = (ph <= 2'd1);
    end
    else if (is_rx) begin
        // 释放 SDA，让从机 / 上拉决定
        scl_oen_c = (ph == 2'd0) | (ph == 2'd3);
        sda_oen_c = 1'b0;
    end
    else begin
        scl_oen_c = (ph == 2'd0) | (ph == 2'd3);
        sda_oen_c = ~txb;
    end
end

always @(posedge clk) begin
    if (rst) begin
        scl_oen <= 1'b0;                // 批注：复位释放SCL
        sda_oen <= 1'b0;                // SDA 释放（高），避免进 START 时造成假跳变
    end
    else begin
        scl_oen <= scl_oen_c;
        sda_oen <= sda_oen_c;
    end
end

assign scl = scl_oen ? 1'b0 : 1'bz;
assign sda = sda_oen ? 1'b0 : 1'bz;

// ---------------- 主状态机 ----------------
always @(posedge clk) begin
    if (rst) begin
        st     <= S_IDLE;
        bc     <= 4'd0;
        sh     <= 8'd0;
        nb     <= 8'd0;
        rd_r   <= 1'b0;
        dev_r<=0;idx_r<=0;wdata_r<=0;nbytes_r<=0;
        rdata  <= 8'd0;
        rvld   <= 1'b0;
        busy   <= 1'b0;
        done   <= 1'b0;
        ackerr <= 1'b0;
    end
    else begin
        rvld <= 1'b0;
        done <= 1'b0;

        // ---- 读方向：在 ph2 末尾采样 ----
        if (smp_tick) begin
            if (st == S_RBYTE) begin
                sh <= {sh[6:0], sda_i};          // 8 次之后就是整字节
            end
            else if (is_rx) begin
                if (sda_i) ackerr <= 1'b1;       // 第 9 拍读到 1 = NACK
            end
        end

        // ---- 槽结束：推进序列 ----
        if (slot_done) begin
            case (st)

            S_IDLE: ;     // 见下面 go 分支

            S_START: begin
                st <= S_ADDR;
                sh <= {dev_r, 1'b0};               // 先按"写"方向发地址
                bc <= 4'd0;
            end

            S_ADDR: begin
                if (bc == 4'd7) st <= S_ACK1;
                else begin bc <= bc + 4'd1; sh <= {sh[6:0], 1'b0}; end
            end

            S_ACK1: begin
                if (ackerr) st <= S_STOP;        // 从机没应答 → 直接收尾
                else begin st <= S_IDX; sh <= idx_r; bc <= 4'd0; end
            end

            S_IDX: begin
                if (bc == 4'd7) st <= S_ACK2;
                else begin bc <= bc + 4'd1; sh <= {sh[6:0], 1'b0}; end
            end

            S_ACK2: begin
                if (ackerr) st <= S_STOP;
                else if (rd_r) st <= S_REST;
                else begin st <= S_WDATA; sh <= wdata_r; bc <= 4'd0; end
            end

            S_REST: begin
                st <= S_ADDRR;
                sh <= {dev_r, 1'b1};               // 读方向：地址 + R
                bc <= 4'd0;
            end

            S_ADDRR: begin
                if (bc == 4'd7) st <= S_ACK3;
                else begin bc <= bc + 4'd1; sh <= {sh[6:0], 1'b0}; end
            end

            S_ACK3: begin
                if (ackerr) st <= S_STOP;
                else begin st <= S_RBYTE; bc <= 4'd0; nb <= {3'b0,nbytes_r}; end
            end

            S_RBYTE: begin
                if (bc == 4'd7) begin
                    rdata <= sh;                 // sh 已在 ph2 采样点更新完毕
                    rvld  <= 1'b1;
                    st    <= S_MACK;
                    bc    <= 4'd0;
                end
                else bc <= bc + 4'd1;
            end

            S_MACK: begin
                if (nb == 8'd0) st <= S_STOP;    // 全部读完
                else begin
                    nb <= nb - 8'd1;
                    bc <= 4'd0;
                    st <= S_RBYTE;
                end
            end

            S_WDATA: begin
                if (bc == 4'd7) st <= S_ACK4;
                else begin bc <= bc + 4'd1; sh <= {sh[6:0], 1'b0}; end
            end

            S_ACK4: begin
                st <= S_STOP;
            end

            S_STOP: begin
                st   <= S_IDLE;
                busy <= 1'b0;
                done <= 1'b1;
            end

            default: st <= S_IDLE;
            endcase
        end

        if (st == S_IDLE && go && !busy) begin
            ackerr <= 1'b0;
            busy   <= 1'b1;
            rd_r   <= rd;
            dev_r<=dev;idx_r<=idx;wdata_r<=wdata;nbytes_r<=nbytes;
            bc     <= 4'd0;
            st     <= S_START;
        end
        if(timed_out) begin
            st<=S_IDLE;busy<=0;done<=1;ackerr<=1;rvld<=0;
        end
    end
end

endmodule
