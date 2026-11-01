module adsr(
    input             clk,          
    input             rst,
    input             gate,
    input [1:0]       profile,      
    input             trig,         
    output reg [15:0] envelope
);

// 曲线形状：5 = 钢琴感指数（每步 0.276 dB）    15 = 纯线性
parameter INSTRUMENT_PRESETS = 0;
parameter [4:0] SH = 5'd5;

localparam IDLE    = 3'd0,
           ATTACK  = 3'd1,
           DECAY   = 3'd2,
           SUSTAIN = 3'd3,
           RELEASE = 3'd4;
parameter [23:0] ATTACK_TIME   = 24'd2500;      // 每级50us，起音约16ms @50MHz
parameter [23:0] DECAY_TIME    = 24'd500000;    // 每级10ms，衰减到25%约440ms
parameter [23:0] RELEASE_TIME  = 24'd100000;    // 每级2ms，释放拖尾约0.6s

localparam [15:0] MAX_LEVEL     = 16'd32767;
parameter [15:0] SUSTAIN_LEVEL = 16'd8192;     
wire flute = INSTRUMENT_PRESETS && profile==2'd0;
wire clarinet = INSTRUMENT_PRESETS && profile==2'd2;
wire [23:0] attack_limit = flute ? 24'd3176 : ATTACK_TIME;
wire [23:0] decay_limit = flute ? 24'd125000 : DECAY_TIME;
wire [23:0] release_limit = flute ? 24'd21185 : clarinet ? 24'd42000 : RELEASE_TIME;
wire [15:0] sustain_value = flute ? 16'd28000 : clarinet ? 16'd21000 : SUSTAIN_LEVEL;
reg [2:0]  state;
reg [2:0]  state_d;
reg [23:0] counter;

wire state_chg = (state != state_d);

// 指数步长（组合）
wire [15:0] inc_up = ((MAX_LEVEL - envelope) >> SH) + 16'd1;   
wire [15:0] inc_dn = (envelope >> SH) + 16'd1;                 

// ---------------- 状态变化检测 ----------------
always @(posedge clk) begin
    if (rst) state_d <= IDLE;
    else     state_d <= state;
end

// ---------------- 计数器：状态一变 / 重触发 立即归零 ----------------
always @(posedge clk) begin
    if (rst)            counter <= 24'd0;
    else if (trig)      counter <= 24'd0;
    else if (state_chg) counter <= 24'd0;
    else 
    case (state)
        ATTACK : counter <= (counter >= attack_limit ) ? 24'd0 : counter + 24'd1;
        DECAY  : counter <= (counter >= decay_limit  ) ? 24'd0 : counter + 24'd1;
        RELEASE: counter <= (counter >= release_limit) ? 24'd0 : counter + 24'd1;
        default: counter <= 24'd0;
    endcase
end

// ---------------- 状态机 ----------------
always @(posedge clk) begin
    if (rst) begin
        state    <= IDLE;
        envelope <= 16'd0;
    end
    else if (trig) begin
        state    <= ATTACK;
        envelope <= 16'd0;
    end
    else 
    case (state)
        IDLE: begin
            envelope <= 16'd0;
            if (gate) state <= ATTACK;
        end
        ATTACK: begin
            if (!gate)
                state <= RELEASE;
            else if (envelope >= MAX_LEVEL)                 // 先判顶，防溢出
                state <= DECAY;
            else if (counter >= attack_limit)
                envelope <= envelope + inc_up;
        end
        DECAY: begin
            if (!gate)
                state <= RELEASE;
            else if (envelope <= sustain_value)             // 衰减到 sustain_value 才停
                state <= SUSTAIN;
            else if (counter >= decay_limit)
                envelope <= (envelope <= inc_dn) ? 16'd0 : envelope - inc_dn;
        end
        SUSTAIN: begin
            envelope <= sustain_value;
            if (!gate) state <= RELEASE;
        end
        RELEASE: begin
            if (gate)
                state <= ATTACK;
            else if (envelope == 16'd0)
                state <= IDLE;
            else if (counter >= release_limit)
                envelope <= (envelope <= inc_dn) ? 16'd0 : envelope - inc_dn;
        end
        default: state <= IDLE;
    endcase
end
endmodule
