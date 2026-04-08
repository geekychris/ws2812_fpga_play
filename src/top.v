module top (
	input 		clk,
	input 		s0,
	output reg 	WS2812
);

parameter NUM_LEDS 		= 64;
parameter WS2812_WIDTH 	= 24;
parameter CLK_FRE 		= 27_000_000;

parameter DELAY_1_HIGH 	= (CLK_FRE / 1_000_000 * 0.85) - 1;
parameter DELAY_1_LOW 	= (CLK_FRE / 1_000_000 * 0.40) - 1;
parameter DELAY_0_HIGH 	= (CLK_FRE / 1_000_000 * 0.40) - 1;
parameter DELAY_0_LOW 	= (CLK_FRE / 1_000_000 * 0.85) - 1;
parameter DELAY_RESET 	= (CLK_FRE / 100) - 1; // ~10ms frame period (~100fps)

// States
localparam S_RESET         = 3'd0;
localparam S_LOAD_COLOR    = 3'd1;
localparam S_DATA_SEND     = 3'd2;
localparam S_BIT_SEND_HIGH = 3'd3;
localparam S_BIT_SEND_LOW  = 3'd4;

// Effects
localparam NUM_EFFECTS     = 5;
localparam EFF_RAINBOW     = 3'd0;
localparam EFF_CHASE       = 3'd1;
localparam EFF_PULSE       = 3'd2;
localparam EFF_COMET       = 3'd3;
localparam EFF_SOLID_CYCLE = 3'd4;

// WS2812 driver state
reg [2:0]  state        = S_RESET;
reg [4:0]  bit_send     = 0;
reg [8:0]  data_send    = 0;
reg [31:0] clk_count    = 0;
reg [23:0] current_color = 0;

// Animation
reg [15:0] frame_count  = 0;
reg [2:0]  effect_sel   = 0;
reg [8:0]  anim_pos     = 0;
reg [3:0]  anim_subdiv  = 0;

// ---- Button debounce ----
reg [19:0] btn_cnt    = 0;
reg        btn_sync0  = 1, btn_sync1 = 1;
reg        btn_stable = 1, btn_prev  = 1;

always @(posedge clk) begin
	btn_sync0 <= s0;
	btn_sync1 <= btn_sync0;
end

always @(posedge clk) begin
	if (btn_sync1 != btn_stable) begin
		if (btn_cnt == 20'd540_000) begin
			btn_stable <= btn_sync1;
			btn_cnt <= 0;
		end else
			btn_cnt <= btn_cnt + 1;
	end else
		btn_cnt <= 0;
end

always @(posedge clk) begin
	btn_prev <= btn_stable;
	if (btn_prev && !btn_stable)
		effect_sel <= (effect_sel == NUM_EFFECTS - 1) ? 3'd0 : effect_sel + 1;
end

// ---- HSV to RGB (combinational) ----
// Input: hsv_hue (0-255), hsv_val (brightness 0-255)
// Output: rgb_r, rgb_g, rgb_b
// Full saturation assumed
reg [7:0]  hsv_hue;
reg [7:0]  hsv_val;
reg [7:0]  rgb_r, rgb_g, rgb_b;
reg [7:0]  h_frac;
reg [15:0] mul_tmp;
reg [7:0]  rising, falling;

always @(*) begin
	rgb_r = 0;
	rgb_g = 0;
	rgb_b = 0;
	h_frac = 0;
	mul_tmp = 0;
	rising = 0;
	falling = 0;

	if (hsv_hue < 8'd43) begin
		h_frac = hsv_hue * 6;
		mul_tmp = hsv_val * h_frac;
		rising = mul_tmp[15:8];
		rgb_r = hsv_val; rgb_g = rising; rgb_b = 0;
	end else if (hsv_hue < 8'd86) begin
		h_frac = (hsv_hue - 8'd43) * 6;
		mul_tmp = hsv_val * (8'd255 - h_frac);
		falling = mul_tmp[15:8];
		rgb_r = falling; rgb_g = hsv_val; rgb_b = 0;
	end else if (hsv_hue < 8'd129) begin
		h_frac = (hsv_hue - 8'd86) * 6;
		mul_tmp = hsv_val * h_frac;
		rising = mul_tmp[15:8];
		rgb_r = 0; rgb_g = hsv_val; rgb_b = rising;
	end else if (hsv_hue < 8'd172) begin
		h_frac = (hsv_hue - 8'd129) * 6;
		mul_tmp = hsv_val * (8'd255 - h_frac);
		falling = mul_tmp[15:8];
		rgb_r = 0; rgb_g = falling; rgb_b = hsv_val;
	end else if (hsv_hue < 8'd215) begin
		h_frac = (hsv_hue - 8'd172) * 6;
		mul_tmp = hsv_val * h_frac;
		rising = mul_tmp[15:8];
		rgb_r = rising; rgb_g = 0; rgb_b = hsv_val;
	end else begin
		h_frac = (hsv_hue - 8'd215) * 6;
		mul_tmp = hsv_val * (8'd255 - h_frac);
		falling = mul_tmp[15:8];
		rgb_r = hsv_val; rgb_g = 0; rgb_b = falling;
	end
end

// ---- Effect color computation (combinational) ----
reg [7:0] comp_hue;
reg [7:0] comp_val;
reg [8:0] led_dist;

always @(*) begin
	comp_hue = 0;
	comp_val = 8'd128;
	led_dist = 0;

	case (effect_sel)
		EFF_RAINBOW: begin
			// Each LED offset in hue, all rotate together
			comp_hue = frame_count[7:0] + (data_send[7:0] * (256 / NUM_LEDS));
			comp_val = 8'd128;
		end

		EFF_CHASE: begin
			// Single bright LED moves along the strip
			comp_hue = frame_count[9:2];
			comp_val = (data_send == anim_pos) ? 8'd255 : 8'd0;
		end

		EFF_PULSE: begin
			// All LEDs breathe in unison, slowly shifting hue
			comp_hue = frame_count[11:4];
			comp_val = frame_count[8] ? ~frame_count[7:0] : frame_count[7:0];
		end

		EFF_COMET: begin
			// Bright head with fading tail
			comp_hue = frame_count[11:4];
			if (data_send <= anim_pos)
				led_dist = anim_pos - data_send;
			else
				led_dist = NUM_LEDS - data_send + anim_pos;

			case (led_dist[3:0])
				4'd0:    comp_val = 8'd255;
				4'd1:    comp_val = 8'd180;
				4'd2:    comp_val = 8'd120;
				4'd3:    comp_val = 8'd70;
				4'd4:    comp_val = 8'd30;
				4'd5:    comp_val = 8'd10;
				default: comp_val = 8'd0;
			endcase
		end

		EFF_SOLID_CYCLE: begin
			// All LEDs same color, cycling through hues
			comp_hue = frame_count[7:0];
			comp_val = 8'd128;
		end

		default: begin
			comp_hue = 0;
			comp_val = 8'd128;
		end
	endcase

	hsv_hue = comp_hue;
	hsv_val = comp_val;
end

// GRB output for WS2812
wire [23:0] grb_color = {rgb_g, rgb_r, rgb_b};

// ---- Main WS2812 state machine ----
always @(posedge clk) begin
	case (state)
		S_RESET: begin
			WS2812 <= 0;
			if (clk_count < DELAY_RESET)
				clk_count <= clk_count + 1;
			else begin
				clk_count <= 0;
				frame_count <= frame_count + 1;

				// Advance animation position every 5 frames
				if (anim_subdiv == 4'd4) begin
					anim_subdiv <= 0;
					anim_pos <= (anim_pos == NUM_LEDS - 1) ? 9'd0 : anim_pos + 1;
				end else
					anim_subdiv <= anim_subdiv + 1;

				data_send <= 0;
				bit_send <= 0;
				state <= S_LOAD_COLOR;
			end
		end

		S_LOAD_COLOR: begin
			current_color <= grb_color;
			state <= S_DATA_SEND;
		end

		S_DATA_SEND: begin
			if (bit_send < WS2812_WIDTH)
				state <= S_BIT_SEND_HIGH;
			else if (data_send < NUM_LEDS - 1) begin
				data_send <= data_send + 1;
				bit_send <= 0;
				state <= S_LOAD_COLOR;
			end else begin
				data_send <= 0;
				bit_send <= 0;
				state <= S_RESET;
			end
		end

		S_BIT_SEND_HIGH: begin
			WS2812 <= 1;
			if (current_color[WS2812_WIDTH - 1 - bit_send])
				if (clk_count < DELAY_1_HIGH)
					clk_count <= clk_count + 1;
				else begin
					clk_count <= 0;
					state <= S_BIT_SEND_LOW;
				end
			else
				if (clk_count < DELAY_0_HIGH)
					clk_count <= clk_count + 1;
				else begin
					clk_count <= 0;
					state <= S_BIT_SEND_LOW;
				end
		end

		S_BIT_SEND_LOW: begin
			WS2812 <= 0;
			if (current_color[WS2812_WIDTH - 1 - bit_send])
				if (clk_count < DELAY_1_LOW)
					clk_count <= clk_count + 1;
				else begin
					clk_count <= 0;
					bit_send <= bit_send + 1;
					state <= S_DATA_SEND;
				end
			else
				if (clk_count < DELAY_0_LOW)
					clk_count <= clk_count + 1;
				else begin
					clk_count <= 0;
					bit_send <= bit_send + 1;
					state <= S_DATA_SEND;
				end
		end
	endcase
end

endmodule
