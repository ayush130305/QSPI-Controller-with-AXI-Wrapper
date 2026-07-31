module pulse_sync (
	src_clk,
	src_rstn,
	pulse_in,
	dst_clk,
	dst_rstn,
	pulse_out
);
	input wire src_clk;
	input wire src_rstn;
	input wire pulse_in;
	input wire dst_clk;
	input wire dst_rstn;
	output wire pulse_out;
	reg toggle_src;
	always @(posedge src_clk or negedge src_rstn)
		if (!src_rstn)
			toggle_src <= 1'b0;
		else if (pulse_in)
			toggle_src <= ~toggle_src;
	reg sync_ff1;
	reg sync_ff2;
	reg sync_ff3;
	always @(posedge dst_clk or negedge dst_rstn)
		if (!dst_rstn) begin
			sync_ff1 <= 1'b0;
			sync_ff2 <= 1'b0;
			sync_ff3 <= 1'b0;
		end
		else begin
			sync_ff1 <= toggle_src;
			sync_ff2 <= sync_ff1;
			sync_ff3 <= sync_ff2;
		end
	assign pulse_out = sync_ff2 ^ sync_ff3;
endmodule
module cdc_bridge (
	aclk,
	aclk_rstn,
	qclk,
	qclk_rst,
	axi_start,
	axi_abort,
	axi_ctrl_cmd,
	axi_addr,
	axi_num_bytes,
	axi_busy,
	axi_done,
	axi_error,
	axi_tx_data,
	axi_tx_req,
	axi_rx_data,
	axi_rx_valid,
	qspi_start,
	qspi_abort,
	qspi_ctrl_cmd,
	qspi_addr,
	qspi_num_bytes,
	qspi_busy,
	qspi_done,
	qspi_error,
	qspi_tx_data,
	qspi_tx_req,
	qspi_rx_data,
	qspi_rx_valid
);
	input wire aclk;
	input wire aclk_rstn;
	input wire qclk;
	input wire qclk_rst;
	input wire axi_start;
	input wire axi_abort;
	input wire [31:0] axi_ctrl_cmd;
	input wire [31:0] axi_addr;
	input wire [31:0] axi_num_bytes;
	output wire axi_busy;
	output wire axi_done;
	output wire axi_error;
	input wire [7:0] axi_tx_data;
	output wire axi_tx_req;
	output reg [7:0] axi_rx_data;
	output wire axi_rx_valid;
	output wire qspi_start;
	output wire qspi_abort;
	output wire [31:0] qspi_ctrl_cmd;
	output wire [31:0] qspi_addr;
	output wire [31:0] qspi_num_bytes;
	input wire qspi_busy;
	input wire qspi_done;
	input wire qspi_error;
	output reg [7:0] qspi_tx_data;
	input wire qspi_tx_req;
	input wire [7:0] qspi_rx_data;
	input wire qspi_rx_valid;
	pulse_sync u_start_sync(
		.src_clk(aclk),
		.src_rstn(aclk_rstn),
		.pulse_in(axi_start),
		.dst_clk(qclk),
		.dst_rstn(~qclk_rst),
		.pulse_out(qspi_start)
	);
	pulse_sync u_abort_sync(
		.src_clk(aclk),
		.src_rstn(aclk_rstn),
		.pulse_in(axi_abort),
		.dst_clk(qclk),
		.dst_rstn(~qclk_rst),
		.pulse_out(qspi_abort)
	);
	pulse_sync u_done_sync(
		.src_clk(qclk),
		.src_rstn(~qclk_rst),
		.pulse_in(qspi_done),
		.dst_clk(aclk),
		.dst_rstn(aclk_rstn),
		.pulse_out(axi_done)
	);
	reg error_ff1;
	reg error_ff2;
	always @(posedge aclk or negedge aclk_rstn)
		if (!aclk_rstn) begin
			error_ff1 <= 1'b0;
			error_ff2 <= 1'b0;
		end
		else begin
			error_ff1 <= qspi_error;
			error_ff2 <= error_ff1;
		end
	assign axi_error = error_ff2;
	pulse_sync u_txreq_sync(
		.src_clk(qclk),
		.src_rstn(~qclk_rst),
		.pulse_in(qspi_tx_req),
		.dst_clk(aclk),
		.dst_rstn(aclk_rstn),
		.pulse_out(axi_tx_req)
	);
	pulse_sync u_rxvalid_sync(
		.src_clk(qclk),
		.src_rstn(~qclk_rst),
		.pulse_in(qspi_rx_valid),
		.dst_clk(aclk),
		.dst_rstn(aclk_rstn),
		.pulse_out(axi_rx_valid)
	);
	reg busy_ff1;
	reg busy_ff2;
	always @(posedge aclk or negedge aclk_rstn)
		if (!aclk_rstn) begin
			busy_ff1 <= 1'b0;
			busy_ff2 <= 1'b0;
		end
		else begin
			busy_ff1 <= qspi_busy;
			busy_ff2 <= busy_ff1;
		end
	assign axi_busy = busy_ff2;
	assign qspi_ctrl_cmd = axi_ctrl_cmd;
	assign qspi_addr = axi_addr;
	assign qspi_num_bytes = axi_num_bytes;
	reg [7:0] tx_data_hold;
	reg tx_data_ready;
	always @(posedge aclk or negedge aclk_rstn)
		if (!aclk_rstn) begin
			tx_data_hold <= 1'sb0;
			tx_data_ready <= 1'b0;
		end
		else begin
			tx_data_ready <= 1'b0;
			if (axi_start || axi_tx_req) begin
				tx_data_hold <= axi_tx_data;
				tx_data_ready <= 1'b1;
			end
		end
	wire tx_data_ready_q;
	pulse_sync u_tx_ready_sync(
		.src_clk(aclk),
		.src_rstn(aclk_rstn),
		.pulse_in(tx_data_ready),
		.dst_clk(qclk),
		.dst_rstn(~qclk_rst),
		.pulse_out(tx_data_ready_q)
	);
	always @(posedge qclk or posedge qclk_rst)
		if (qclk_rst)
			qspi_tx_data <= 1'sb0;
		else if (tx_data_ready_q)
			qspi_tx_data <= tx_data_hold;
	reg [7:0] rx_data_hold;
	always @(posedge qclk or posedge qclk_rst)
		if (qclk_rst)
			rx_data_hold <= 1'sb0;
		else if (qspi_rx_valid)
			rx_data_hold <= qspi_rx_data;
	always @(posedge aclk or negedge aclk_rstn)
		if (!aclk_rstn)
			axi_rx_data <= 1'sb0;
		else if (axi_rx_valid)
			axi_rx_data <= rx_data_hold;
endmodule
module axi4L_slave (
	ACLK,
	ARESETn,
	AXI_AWADDR,
	AXI_AWVALID,
	AXI_AWREADY,
	AXI_WDATA,
	AXI_WSTRB,
	AXI_WVALID,
	AXI_WREADY,
	AXI_BRESP,
	AXI_BVALID,
	AXI_BREADY,
	AXI_ARADDR,
	AXI_ARVALID,
	AXI_ARREADY,
	AXI_RDATA,
	AXI_RRESP,
	AXI_RVALID,
	AXI_RREADY,
	qspi_start,
	qspi_abort,
	qspi_ctrl_cmd,
	qspi_addr,
	qspi_num_bytes,
	qspi_busy,
	qspi_done,
	qspi_error,
	qspi_tx_data,
	qspi_tx_req,
	qspi_rx_data,
	qspi_rx_valid,
	xip_cfg
);
	reg _sv2v_0;
	input wire ACLK;
	input wire ARESETn;
	input wire [31:0] AXI_AWADDR;
	input wire AXI_AWVALID;
	output reg AXI_AWREADY;
	input wire [31:0] AXI_WDATA;
	input wire [3:0] AXI_WSTRB;
	input wire AXI_WVALID;
	output reg AXI_WREADY;
	output reg [1:0] AXI_BRESP;
	output reg AXI_BVALID;
	input wire AXI_BREADY;
	input wire [31:0] AXI_ARADDR;
	input wire AXI_ARVALID;
	output reg AXI_ARREADY;
	output reg [31:0] AXI_RDATA;
	output reg [1:0] AXI_RRESP;
	output reg AXI_RVALID;
	input wire AXI_RREADY;
	output wire qspi_start;
	output wire qspi_abort;
	output wire [31:0] qspi_ctrl_cmd;
	output wire [31:0] qspi_addr;
	output wire [31:0] qspi_num_bytes;
	input wire qspi_busy;
	input wire qspi_done;
	input wire qspi_error;
	output wire [7:0] qspi_tx_data;
	input wire qspi_tx_req;
	input wire [7:0] qspi_rx_data;
	input wire qspi_rx_valid;
	output wire [31:0] xip_cfg;
	reg [31:0] reg_ctrl_cmd;
	reg [31:0] reg_addr;
	reg [31:0] reg_num_bytes;
	reg [31:0] reg_tx_data;
	reg [31:0] reg_xip_cfg;
	assign xip_cfg = reg_xip_cfg;
	reg [1:0] state;
	wire aw_hs;
	wire w_hs;
	wire b_hs;
	wire ar_hs;
	wire r_hs;
	assign aw_hs = AXI_AWVALID & AXI_AWREADY;
	assign w_hs = AXI_WVALID & AXI_WREADY;
	assign b_hs = AXI_BVALID & AXI_BREADY;
	assign ar_hs = AXI_ARVALID & AXI_ARREADY;
	assign r_hs = AXI_RVALID & AXI_RREADY;
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn)
			state <= 2'd0;
		else
			case (state)
				2'd0:
					if (aw_hs && w_hs)
						state <= 2'd3;
					else if (aw_hs)
						state <= 2'd1;
					else if (w_hs)
						state <= 2'd2;
				2'd1:
					if (w_hs)
						state <= 2'd3;
				2'd2:
					if (aw_hs)
						state <= 2'd3;
				2'd3:
					if (b_hs)
						state <= 2'd0;
			endcase
	reg [31:0] aw_addr_latched;
	reg [31:0] w_data_latched;
	reg [3:0] w_strb_latched;
	reg [31:0] ar_addr_latched;
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn) begin
			aw_addr_latched <= 1'sb0;
			w_data_latched <= 1'sb0;
			w_strb_latched <= 1'sb0;
			ar_addr_latched <= 1'sb0;
		end
		else begin
			if (aw_hs)
				aw_addr_latched <= AXI_AWADDR;
			if (w_hs)
				w_data_latched <= AXI_WDATA;
			if (w_hs)
				w_strb_latched <= AXI_WSTRB;
			if (ar_hs)
				ar_addr_latched <= AXI_ARADDR;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		AXI_AWREADY = (state == 2'd0) || (state == 2'd2);
		AXI_WREADY = (state == 2'd0) || (state == 2'd1);
		AXI_BVALID = state == 2'd3;
		AXI_BRESP = 2'b00;
	end
	wire do_write;
	wire [31:0] eff_addr;
	wire [31:0] eff_data;
	wire [3:0] eff_strb;
	assign eff_addr = (aw_hs ? AXI_AWADDR : aw_addr_latched);
	assign eff_data = (w_hs ? AXI_WDATA : w_data_latched);
	assign eff_strb = (w_hs ? AXI_WSTRB : w_strb_latched);
	assign do_write = ((((state == 2'd0) && aw_hs) && w_hs) || ((state == 2'd1) && w_hs)) || ((state == 2'd2) && aw_hs);
	reg [1:0] read_state;
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn)
			read_state <= 2'd0;
		else
			case (read_state)
				2'd0:
					if (ar_hs)
						read_state <= 2'd1;
				2'd1:
					if (r_hs)
						read_state <= 2'd0;
				default: read_state <= 2'd0;
			endcase
	reg done_latched;
	reg error_latched;
	reg rx_ready_latched;
	reg tx_ready_latched;
	localparam signed [31:0] qspi_axi_pkg_REG_ADDR = 'h4;
	localparam signed [31:0] qspi_axi_pkg_REG_CTRL_CMD = 'h0;
	localparam signed [31:0] qspi_axi_pkg_REG_NUM_BYTES = 'h8;
	localparam signed [31:0] qspi_axi_pkg_REG_RX_DATA = 'h14;
	localparam signed [31:0] qspi_axi_pkg_REG_STATUS = 'hc;
	localparam signed [31:0] qspi_axi_pkg_REG_TX_DATA = 'h10;
	localparam signed [31:0] qspi_axi_pkg_REG_XIP_CFG = 'h18;
	always @(*) begin
		if (_sv2v_0)
			;
		AXI_ARREADY = read_state == 2'd0;
		AXI_RVALID = read_state == 2'd1;
		AXI_RRESP = 2'b00;
		case (ar_addr_latched)
			qspi_axi_pkg_REG_CTRL_CMD: AXI_RDATA = reg_ctrl_cmd;
			qspi_axi_pkg_REG_ADDR: AXI_RDATA = reg_addr;
			qspi_axi_pkg_REG_NUM_BYTES: AXI_RDATA = reg_num_bytes;
			qspi_axi_pkg_REG_STATUS: AXI_RDATA = {27'd0, error_latched, rx_ready_latched, tx_ready_latched, done_latched, qspi_busy};
			qspi_axi_pkg_REG_TX_DATA: AXI_RDATA = 1'sb0;
			qspi_axi_pkg_REG_XIP_CFG: AXI_RDATA = reg_xip_cfg;
			qspi_axi_pkg_REG_RX_DATA: AXI_RDATA = {24'd0, qspi_rx_data};
			default: AXI_RDATA = 1'sb0;
		endcase
	end
	reg qspi_error_d1;
	wire status_w1c_done;
	wire status_w1c_error;
	localparam signed [31:0] qspi_axi_pkg_STATUS_BIT_DONE = 1;
	assign status_w1c_done = ((do_write && (eff_addr == qspi_axi_pkg_REG_STATUS)) && eff_strb[0]) && eff_data[qspi_axi_pkg_STATUS_BIT_DONE];
	localparam signed [31:0] qspi_axi_pkg_STATUS_BIT_ERROR = 4;
	assign status_w1c_error = ((do_write && (eff_addr == qspi_axi_pkg_REG_STATUS)) && eff_strb[0]) && eff_data[qspi_axi_pkg_STATUS_BIT_ERROR];
	wire tx_data_write;
	wire rx_data_read;
	assign tx_data_write = do_write && (eff_addr == qspi_axi_pkg_REG_TX_DATA);
	assign rx_data_read = r_hs && (ar_addr_latched == qspi_axi_pkg_REG_RX_DATA);
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn) begin
			done_latched <= 1'b0;
			tx_ready_latched <= 1'b0;
			rx_ready_latched <= 1'b0;
			error_latched <= 1'b0;
			qspi_error_d1 <= 1'b0;
		end
		else begin
			qspi_error_d1 <= qspi_error;
			if (qspi_done)
				done_latched <= 1'b1;
			else if (qspi_start)
				done_latched <= 1'b0;
			else if (status_w1c_done)
				done_latched <= 1'b0;
			if (qspi_tx_req)
				tx_ready_latched <= 1'b1;
			else if (tx_data_write)
				tx_ready_latched <= 1'b0;
			if (qspi_rx_valid)
				rx_ready_latched <= 1'b1;
			else if (rx_data_read)
				rx_ready_latched <= 1'b0;
			if (qspi_error && !qspi_error_d1)
				error_latched <= 1'b1;
			else if (qspi_start)
				error_latched <= 1'b0;
			else if (status_w1c_error)
				error_latched <= 1'b0;
		end
	assign qspi_start = (do_write && (eff_addr == qspi_axi_pkg_REG_CTRL_CMD)) && eff_data[21];
	localparam signed [31:0] qspi_axi_pkg_CTRL_BIT_ABORT = 23;
	assign qspi_abort = (do_write && (eff_addr == qspi_axi_pkg_REG_CTRL_CMD)) && eff_data[qspi_axi_pkg_CTRL_BIT_ABORT];
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn) begin
			reg_ctrl_cmd <= 1'sb0;
			reg_addr <= 1'sb0;
			reg_num_bytes <= 1'sb0;
			reg_tx_data <= 1'sb0;
			reg_xip_cfg <= 1'sb0;
		end
		else if (do_write)
			case (eff_addr)
				qspi_axi_pkg_REG_CTRL_CMD: begin : sv2v_autoblock_1
					reg signed [31:0] i;
					for (i = 0; i < 4; i = i + 1)
						if (eff_strb[i])
							reg_ctrl_cmd[i * 8+:8] <= eff_data[i * 8+:8];
				end
				qspi_axi_pkg_REG_ADDR: begin : sv2v_autoblock_2
					reg signed [31:0] i;
					for (i = 0; i < 4; i = i + 1)
						if (eff_strb[i])
							reg_addr[i * 8+:8] <= eff_data[i * 8+:8];
				end
				qspi_axi_pkg_REG_NUM_BYTES: begin : sv2v_autoblock_3
					reg signed [31:0] i;
					for (i = 0; i < 4; i = i + 1)
						if (eff_strb[i])
							reg_num_bytes[i * 8+:8] <= eff_data[i * 8+:8];
				end
				qspi_axi_pkg_REG_TX_DATA: begin : sv2v_autoblock_4
					reg signed [31:0] i;
					for (i = 0; i < 4; i = i + 1)
						if (eff_strb[i])
							reg_tx_data[i * 8+:8] <= eff_data[i * 8+:8];
				end
				qspi_axi_pkg_REG_XIP_CFG: begin : sv2v_autoblock_5
					reg signed [31:0] i;
					for (i = 0; i < 4; i = i + 1)
						if (eff_strb[i])
							reg_xip_cfg[i * 8+:8] <= eff_data[i * 8+:8];
				end
				default:
					;
			endcase
	assign qspi_tx_data = reg_tx_data[7:0];
	assign qspi_ctrl_cmd = reg_ctrl_cmd;
	assign qspi_addr = reg_addr;
	assign qspi_num_bytes = reg_num_bytes;
	initial _sv2v_0 = 0;
endmodule
module qspi_engine (
	sclk,
	sclk_rst,
	cs_n,
	io0_out,
	io0_oe,
	io0_in,
	io1_out,
	io1_oe,
	io1_in,
	io2_out,
	io2_oe,
	io2_in,
	io3_out,
	io3_oe,
	io3_in,
	qspi_start,
	qspi_abort,
	qspi_ctrl_cmd,
	qspi_addr,
	qspi_num_bytes,
	qspi_busy,
	qspi_done,
	qspi_error,
	qspi_tx_data,
	qspi_tx_req,
	qspi_rx_data,
	qspi_rx_valid
);
	reg _sv2v_0;
	parameter [31:0] TIMEOUT_CYCLES = 20'hfffff;
	input wire sclk;
	input wire sclk_rst;
	output wire cs_n;
	output reg io0_out;
	output reg io0_oe;
	input wire io0_in;
	output reg io1_out;
	output reg io1_oe;
	input wire io1_in;
	output reg io2_out;
	output reg io2_oe;
	input wire io2_in;
	output reg io3_out;
	output reg io3_oe;
	input wire io3_in;
	input wire qspi_start;
	input wire qspi_abort;
	input wire [31:0] qspi_ctrl_cmd;
	input wire [31:0] qspi_addr;
	input wire [31:0] qspi_num_bytes;
	output wire qspi_busy;
	output wire qspi_done;
	output wire qspi_error;
	input wire [7:0] qspi_tx_data;
	output wire qspi_tx_req;
	output wire [7:0] qspi_rx_data;
	output wire qspi_rx_valid;
	localparam [1:0] LW_S = 2'd0;
	localparam [1:0] LW_D = 2'd1;
	localparam [1:0] LW_Q = 2'd2;
	reg [1:0] phase;
	reg [15:0] bit_cnt;
	reg busy_r;
	reg [22:0] ctrl;
	reg [31:0] addr_lat;
	reg [31:0] num_bytes_lat;
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst) begin
			ctrl <= 1'sb0;
			addr_lat <= 1'sb0;
			num_bytes_lat <= 1'sb0;
		end
		else if (!busy_r && qspi_start) begin
			ctrl <= qspi_ctrl_cmd[22:0];
			addr_lat <= qspi_addr;
			num_bytes_lat <= qspi_num_bytes;
		end
	function automatic [31:0] lines_per_clock;
		input reg [1:0] lw;
		case (lw)
			LW_S: lines_per_clock = 1;
			LW_D: lines_per_clock = 2;
			LW_Q: lines_per_clock = 4;
			default: lines_per_clock = 1;
		endcase
	endfunction
	reg [15:0] phase_limit;
	reg [15:0] addr_clocks;
	reg [15:0] data_clocks;
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		addr_clocks = (ctrl[12] ? 16'd32 : 16'd24) / lines_per_clock(ctrl[9-:2]);
		data_clocks = (sv2v_cast_16(num_bytes_lat[11:0]) * 16'd8) / lines_per_clock(ctrl[11-:2]);
		case (phase)
			2'd0: phase_limit = 16'd7;
			2'd1: phase_limit = addr_clocks - 1'b1;
			2'd2: phase_limit = (ctrl[20-:8] == 0 ? 16'd0 : {8'b00000000, ctrl[20-:8]} - 16'd1);
			2'd3: phase_limit = (data_clocks == 0 ? 16'd0 : data_clocks - 1'b1);
			default: phase_limit = 16'd0;
		endcase
	end
	reg [31:0] timeout_cnt;
	wire timeout_hit;
	assign timeout_hit = busy_r && (timeout_cnt >= TIMEOUT_CYCLES);
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst)
			timeout_cnt <= 1'sb0;
		else if (!busy_r)
			timeout_cnt <= 1'sb0;
		else
			timeout_cnt <= timeout_cnt + 1'b1;
	reg error_r;
	assign qspi_error = error_r;
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst) begin
			phase <= 2'd0;
			bit_cnt <= 1'sb0;
			busy_r <= 1'b0;
			error_r <= 1'b0;
		end
		else if (qspi_abort || timeout_hit) begin
			busy_r <= 1'b0;
			phase <= 2'd0;
			bit_cnt <= 1'sb0;
			if (timeout_hit)
				error_r <= 1'b1;
		end
		else if (!busy_r) begin
			if (qspi_start) begin
				busy_r <= 1'b1;
				phase <= 2'd0;
				bit_cnt <= 1'sb0;
				error_r <= 1'b0;
			end
		end
		else if (bit_cnt == phase_limit) begin
			if (phase == 2'd3) begin
				busy_r <= 1'b0;
				phase <= 2'd0;
				bit_cnt <= 1'sb0;
			end
			else begin
				bit_cnt <= 1'sb0;
				case (phase)
					2'd0: phase <= 2'd1;
					2'd1: phase <= (ctrl[20-:8] > 0 ? 2'd2 : 2'd3);
					2'd2: phase <= 2'd3;
					default: phase <= 2'd0;
				endcase
			end
		end
		else
			bit_cnt <= bit_cnt + 1'b1;
	assign qspi_busy = busy_r;
	assign qspi_done = (busy_r && (phase == 2'd3)) && (bit_cnt == phase_limit);
	assign cs_n = !busy_r;
	reg [39:0] out_shift;
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst)
			out_shift <= 1'sb0;
		else if (!busy_r && qspi_start)
			out_shift <= (qspi_ctrl_cmd[12] ? {qspi_ctrl_cmd[7:0], qspi_addr} : {qspi_ctrl_cmd[7:0], qspi_addr[23:0], 8'h00});
		else if (busy_r && (phase == 2'd0))
			out_shift <= out_shift << 1;
		else if (busy_r && (phase == 2'd1))
			out_shift <= out_shift << lines_per_clock(ctrl[9-:2]);
	reg [7:0] tx_shift_byte;
	reg [7:0] in_byte;
	wire [3:0] clocks_per_byte;
	reg [3:0] byte_bit_cnt;
	wire byte_boundary;
	function automatic [3:0] sv2v_cast_4;
		input reg [3:0] inp;
		sv2v_cast_4 = inp;
	endfunction
	assign clocks_per_byte = sv2v_cast_4(8 / lines_per_clock(ctrl[11-:2]));
	assign byte_boundary = (busy_r && (phase == 2'd3)) && (byte_bit_cnt == (clocks_per_byte - 4'd1));
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst)
			byte_bit_cnt <= 1'sb0;
		else if (busy_r && (phase == 2'd3)) begin
			if (byte_bit_cnt == (clocks_per_byte - 4'd1))
				byte_bit_cnt <= 1'sb0;
			else
				byte_bit_cnt <= byte_bit_cnt + 4'd1;
		end
		else
			byte_bit_cnt <= 1'sb0;
	wire entering_data_from_addr;
	wire entering_data_from_dummy;
	assign entering_data_from_addr = ((busy_r && (phase == 2'd1)) && (bit_cnt == phase_limit)) && (ctrl[20-:8] == 0);
	assign entering_data_from_dummy = (busy_r && (phase == 2'd2)) && (bit_cnt == phase_limit);
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst) begin
			tx_shift_byte <= 1'sb0;
			in_byte <= 1'sb0;
		end
		else if (ctrl[22] && ((entering_data_from_addr || entering_data_from_dummy) || byte_boundary))
			tx_shift_byte <= qspi_tx_data;
		else if (busy_r && (phase == 2'd3)) begin
			if (ctrl[22])
				tx_shift_byte <= tx_shift_byte << lines_per_clock(ctrl[11-:2]);
			else
				case (ctrl[11-:2])
					LW_S: in_byte <= (in_byte << 1) | {7'b0000000, io0_in};
					LW_D: in_byte <= (in_byte << 2) | {6'b000000, io1_in, io0_in};
					LW_Q: in_byte <= (in_byte << 4) | {4'b0000, io3_in, io2_in, io1_in, io0_in};
					default: in_byte <= (in_byte << 1) | {7'b0000000, io0_in};
				endcase
		end
	reg byte_boundary_d1;
	always @(posedge sclk or posedge sclk_rst)
		if (sclk_rst)
			byte_boundary_d1 <= 1'b0;
		else
			byte_boundary_d1 <= byte_boundary;
	assign qspi_tx_req = byte_boundary && ctrl[22];
	assign qspi_rx_valid = byte_boundary_d1 && !ctrl[22];
	assign qspi_rx_data = in_byte;
	always @(*) begin
		if (_sv2v_0)
			;
		io0_oe = 0;
		io1_oe = 0;
		io2_oe = 0;
		io3_oe = 0;
		io0_out = 0;
		io1_out = 0;
		io2_out = 0;
		io3_out = 0;
		if (busy_r)
			case (phase)
				2'd0: begin
					io0_oe = 1;
					io0_out = out_shift[39];
				end
				2'd1:
					case (ctrl[9-:2])
						LW_S: begin
							io0_oe = 1;
							io0_out = out_shift[39];
						end
						LW_D: begin
							io0_oe = 1;
							io1_oe = 1;
							io1_out = out_shift[39];
							io0_out = out_shift[38];
						end
						LW_Q: begin
							io0_oe = 1;
							io1_oe = 1;
							io2_oe = 1;
							io3_oe = 1;
							io3_out = out_shift[39];
							io2_out = out_shift[38];
							io1_out = out_shift[37];
							io0_out = out_shift[36];
						end
						default:
							;
					endcase
				2'd3:
					if (ctrl[22])
						case (ctrl[11-:2])
							LW_S: begin
								io0_oe = 1;
								io0_out = tx_shift_byte[7];
							end
							LW_D: begin
								io0_oe = 1;
								io1_oe = 1;
								io1_out = tx_shift_byte[7];
								io0_out = tx_shift_byte[6];
							end
							LW_Q: begin
								io0_oe = 1;
								io1_oe = 1;
								io2_oe = 1;
								io3_oe = 1;
								io3_out = tx_shift_byte[7];
								io2_out = tx_shift_byte[6];
								io1_out = tx_shift_byte[5];
								io0_out = tx_shift_byte[4];
							end
							default:
								;
						endcase
				default:
					;
			endcase
	end
	initial _sv2v_0 = 0;
endmodule
module qspi_arbiter (
	ACLK,
	ARESETn,
	a_start,
	a_abort,
	a_ctrl_cmd,
	a_addr,
	a_num_bytes,
	a_tx_data,
	a_busy,
	a_done,
	a_error,
	a_tx_req,
	a_rx_data,
	a_rx_valid,
	x_start,
	x_ctrl_cmd,
	x_addr,
	x_num_bytes,
	x_busy,
	x_done,
	x_error,
	x_rx_data,
	x_rx_valid,
	axi_start,
	axi_abort,
	axi_ctrl_cmd,
	axi_addr,
	axi_num_bytes,
	axi_tx_data,
	axi_busy,
	axi_done,
	axi_error,
	axi_tx_req,
	axi_rx_data,
	axi_rx_valid
);
	reg _sv2v_0;
	input wire ACLK;
	input wire ARESETn;
	input wire a_start;
	input wire a_abort;
	input wire [31:0] a_ctrl_cmd;
	input wire [31:0] a_addr;
	input wire [31:0] a_num_bytes;
	input wire [7:0] a_tx_data;
	output wire a_busy;
	output wire a_done;
	output wire a_error;
	output wire a_tx_req;
	output wire [7:0] a_rx_data;
	output wire a_rx_valid;
	input wire x_start;
	input wire [31:0] x_ctrl_cmd;
	input wire [31:0] x_addr;
	input wire [31:0] x_num_bytes;
	output wire x_busy;
	output wire x_done;
	output wire x_error;
	output wire [7:0] x_rx_data;
	output wire x_rx_valid;
	output reg axi_start;
	output reg axi_abort;
	output reg [31:0] axi_ctrl_cmd;
	output reg [31:0] axi_addr;
	output reg [31:0] axi_num_bytes;
	output reg [7:0] axi_tx_data;
	input wire axi_busy;
	input wire axi_done;
	input wire axi_error;
	input wire axi_tx_req;
	input wire [7:0] axi_rx_data;
	input wire axi_rx_valid;
	reg [1:0] grant;
	reg busy_seen;
	reg [3:0] drain_cnt;
	localparam signed [31:0] DRAIN_CYCLES = 4;
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn) begin
			grant <= 2'd0;
			busy_seen <= 1'b0;
			drain_cnt <= 1'sb0;
		end
		else
			case (grant)
				2'd0: begin
					busy_seen <= 1'b0;
					drain_cnt <= 1'sb0;
					if (a_start)
						grant <= 2'd1;
					else if (x_start)
						grant <= 2'd2;
				end
				2'd1, 2'd2:
					if (axi_busy) begin
						busy_seen <= 1'b1;
						drain_cnt <= 1'sb0;
					end
					else if (busy_seen) begin
						if (drain_cnt == 3) begin
							grant <= 2'd0;
							busy_seen <= 1'b0;
							drain_cnt <= 1'sb0;
						end
						else
							drain_cnt <= drain_cnt + 1'b1;
					end
				default: begin
					grant <= 2'd0;
					busy_seen <= 1'b0;
					drain_cnt <= 1'sb0;
				end
			endcase
	always @(*) begin
		if (_sv2v_0)
			;
		axi_start = 1'b0;
		axi_abort = 1'b0;
		axi_ctrl_cmd = 1'sb0;
		axi_addr = 1'sb0;
		axi_num_bytes = 1'sb0;
		axi_tx_data = 1'sb0;
		(* full_case, parallel_case *)
		case (grant)
			2'd0:
				if (a_start) begin
					axi_start = a_start;
					axi_abort = a_abort;
					axi_ctrl_cmd = a_ctrl_cmd;
					axi_addr = a_addr;
					axi_num_bytes = a_num_bytes;
					axi_tx_data = a_tx_data;
				end
				else if (x_start) begin
					axi_start = x_start;
					axi_ctrl_cmd = x_ctrl_cmd;
					axi_addr = x_addr;
					axi_num_bytes = x_num_bytes;
				end
			2'd1: begin
				axi_start = a_start;
				axi_abort = a_abort;
				axi_ctrl_cmd = a_ctrl_cmd;
				axi_addr = a_addr;
				axi_num_bytes = a_num_bytes;
				axi_tx_data = a_tx_data;
			end
			2'd2: begin
				axi_start = x_start;
				axi_ctrl_cmd = x_ctrl_cmd;
				axi_addr = x_addr;
				axi_num_bytes = x_num_bytes;
			end
			default:
				;
		endcase
	end
	wire route_to_reg;
	wire route_to_xip;
	assign route_to_reg = (grant == 2'd1) || ((grant == 2'd0) && a_start);
	assign route_to_xip = (grant == 2'd2) || (((grant == 2'd0) && !a_start) && x_start);
	assign a_rx_data = axi_rx_data;
	assign x_rx_data = axi_rx_data;
	assign a_busy = (route_to_reg ? axi_busy : 1'b0);
	assign a_done = (route_to_reg ? axi_done : 1'b0);
	assign a_error = (route_to_reg ? axi_error : 1'b0);
	assign a_tx_req = (route_to_reg ? axi_tx_req : 1'b0);
	assign a_rx_valid = (route_to_reg ? axi_rx_valid : 1'b0);
	assign x_busy = (route_to_xip ? axi_busy : 1'b0);
	assign x_done = (route_to_xip ? axi_done : 1'b0);
	assign x_error = (route_to_xip ? axi_error : 1'b0);
	assign x_rx_valid = (route_to_xip ? axi_rx_valid : 1'b0);
	initial _sv2v_0 = 0;
endmodule
module qspi_xip_slave (
	ACLK,
	ARESETn,
	AXI_ARADDR,
	AXI_ARVALID,
	AXI_ARREADY,
	AXI_RDATA,
	AXI_RRESP,
	AXI_RVALID,
	AXI_RREADY,
	xip_cfg,
	x_start,
	x_ctrl_cmd,
	x_addr,
	x_num_bytes,
	x_busy,
	x_done,
	x_error,
	x_rx_data,
	x_rx_valid
);
	parameter [31:0] XIP_BASE = 32'h01000000;
	parameter [31:0] XIP_SIZE = 32'h01000000;
	input wire ACLK;
	input wire ARESETn;
	input wire [31:0] AXI_ARADDR;
	input wire AXI_ARVALID;
	output wire AXI_ARREADY;
	output wire [31:0] AXI_RDATA;
	output wire [1:0] AXI_RRESP;
	output wire AXI_RVALID;
	input wire AXI_RREADY;
	input wire [31:0] xip_cfg;
	output reg x_start;
	output wire [31:0] x_ctrl_cmd;
	output wire [31:0] x_addr;
	output wire [31:0] x_num_bytes;
	input wire x_busy;
	input wire x_done;
	input wire x_error;
	input wire [7:0] x_rx_data;
	input wire x_rx_valid;
	localparam signed [31:0] XIP_BEAT_BYTES = 4;
	reg [2:0] state;
	reg [31:0] ar_addr_latched;
	wire [31:0] flash_addr;
	wire addr_in_range_live;
	reg [31:0] assemble_reg;
	reg [2:0] byte_count;
	reg fetch_error;
	reg x_rx_valid_d1;
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn)
			x_rx_valid_d1 <= 1'b0;
		else
			x_rx_valid_d1 <= x_rx_valid;
	assign flash_addr = ar_addr_latched - XIP_BASE;
	assign addr_in_range_live = (AXI_ARADDR >= XIP_BASE) && (AXI_ARADDR < (XIP_BASE + XIP_SIZE));
	assign AXI_ARREADY = state == 3'd0;
	assign AXI_RVALID = state == 3'd3;
	assign AXI_RDATA = assemble_reg;
	assign AXI_RRESP = (fetch_error ? 2'b10 : 2'b00);
	assign x_ctrl_cmd = {11'b00000000001, xip_cfg[20:13], xip_cfg[12], xip_cfg[11:10], xip_cfg[9:8], xip_cfg[7:0]};
	assign x_addr = flash_addr;
	assign x_num_bytes = XIP_BEAT_BYTES;
	localparam signed [31:0] qspi_axi_pkg_XIP_CFG_BIT_ENABLE = 31;
	always @(posedge ACLK or negedge ARESETn)
		if (!ARESETn) begin
			state <= 3'd0;
			ar_addr_latched <= 1'sb0;
			assemble_reg <= 1'sb0;
			byte_count <= 1'sb0;
			fetch_error <= 1'b0;
			x_start <= 1'b0;
		end
		else begin
			x_start <= 1'b0;
			case (state)
				3'd0:
					if (AXI_ARVALID && AXI_ARREADY) begin
						ar_addr_latched <= AXI_ARADDR;
						byte_count <= 1'sb0;
						assemble_reg <= 1'sb0;
						if (xip_cfg[qspi_axi_pkg_XIP_CFG_BIT_ENABLE] && addr_in_range_live) begin
							state <= 3'd1;
							fetch_error <= 1'b0;
						end
						else begin
							state <= 3'd3;
							fetch_error <= 1'b1;
						end
					end
				3'd1: begin
					x_start <= 1'b1;
					state <= 3'd2;
				end
				3'd2:
					if (x_error) begin
						fetch_error <= 1'b1;
						state <= 3'd3;
					end
					else if (x_rx_valid_d1) begin
						case (byte_count)
							0: assemble_reg[7:0] <= x_rx_data;
							1: assemble_reg[15:8] <= x_rx_data;
							2: assemble_reg[23:16] <= x_rx_data;
							3: assemble_reg[31:24] <= x_rx_data;
						endcase
						if (byte_count == 3)
							state <= 3'd3;
						else
							byte_count <= byte_count + 1'b1;
					end
				3'd3:
					if (AXI_RVALID && AXI_RREADY)
						state <= 3'd4;
				3'd4: state <= 3'd0;
				default: state <= 3'd0;
			endcase
		end
endmodule
module qspi_axi_top (
	ACLK,
	ARESETn,
	qclk,
	qclk_rst,
	AXI_AWADDR,
	AXI_AWVALID,
	AXI_AWREADY,
	AXI_WDATA,
	AXI_WSTRB,
	AXI_WVALID,
	AXI_WREADY,
	AXI_BRESP,
	AXI_BVALID,
	AXI_BREADY,
	AXI_ARADDR,
	AXI_ARVALID,
	AXI_ARREADY,
	AXI_RDATA,
	AXI_RRESP,
	AXI_RVALID,
	AXI_RREADY,
	XIP_ARADDR,
	XIP_ARVALID,
	XIP_ARREADY,
	XIP_RDATA,
	XIP_RRESP,
	XIP_RVALID,
	XIP_RREADY,
	cs_n,
	io0_out,
	io0_oe,
	io0_in,
	io1_out,
	io1_oe,
	io1_in,
	io2_out,
	io2_oe,
	io2_in,
	io3_out,
	io3_oe,
	io3_in
);
	parameter [31:0] TIMEOUT_CYCLES = 20'hfffff;
	parameter [31:0] XIP_BASE = 32'h01000000;
	parameter [31:0] XIP_SIZE = 32'h01000000;
	input wire ACLK;
	input wire ARESETn;
	input wire qclk;
	input wire qclk_rst;
	input wire [31:0] AXI_AWADDR;
	input wire AXI_AWVALID;
	output wire AXI_AWREADY;
	input wire [31:0] AXI_WDATA;
	input wire [3:0] AXI_WSTRB;
	input wire AXI_WVALID;
	output wire AXI_WREADY;
	output wire [1:0] AXI_BRESP;
	output wire AXI_BVALID;
	input wire AXI_BREADY;
	input wire [31:0] AXI_ARADDR;
	input wire AXI_ARVALID;
	output wire AXI_ARREADY;
	output wire [31:0] AXI_RDATA;
	output wire [1:0] AXI_RRESP;
	output wire AXI_RVALID;
	input wire AXI_RREADY;
	input wire [31:0] XIP_ARADDR;
	input wire XIP_ARVALID;
	output wire XIP_ARREADY;
	output wire [31:0] XIP_RDATA;
	output wire [1:0] XIP_RRESP;
	output wire XIP_RVALID;
	input wire XIP_RREADY;
	output wire cs_n;
	output wire io0_out;
	output wire io0_oe;
	input wire io0_in;
	output wire io1_out;
	output wire io1_oe;
	input wire io1_in;
	output wire io2_out;
	output wire io2_oe;
	input wire io2_in;
	output wire io3_out;
	output wire io3_oe;
	input wire io3_in;
	wire int_a_start;
	wire int_a_abort;
	wire [31:0] int_a_ctrl_cmd;
	wire [31:0] int_a_addr;
	wire [31:0] int_a_num_bytes;
	wire int_a_busy;
	wire int_a_done;
	wire int_a_error;
	wire [7:0] int_a_tx_data;
	wire int_a_tx_req;
	wire [7:0] int_a_rx_data;
	wire int_a_rx_valid;
	wire [31:0] int_xip_cfg;
	wire int_x_start;
	wire [31:0] int_x_ctrl_cmd;
	wire [31:0] int_x_addr;
	wire [31:0] int_x_num_bytes;
	wire int_x_busy;
	wire int_x_done;
	wire int_x_error;
	wire [7:0] int_x_rx_data;
	wire int_x_rx_valid;
	wire int_m_start;
	wire int_m_abort;
	wire [31:0] int_m_ctrl_cmd;
	wire [31:0] int_m_addr;
	wire [31:0] int_m_num_bytes;
	wire int_m_busy;
	wire int_m_done;
	wire int_m_error;
	wire [7:0] int_m_tx_data;
	wire int_m_tx_req;
	wire [7:0] int_m_rx_data;
	wire int_m_rx_valid;
	wire int_q_start;
	wire int_q_abort;
	wire [31:0] int_q_ctrl_cmd;
	wire [31:0] int_q_addr;
	wire [31:0] int_q_num_bytes;
	wire int_q_busy;
	wire int_q_done;
	wire int_q_error;
	wire [7:0] int_q_tx_data;
	wire int_q_tx_req;
	wire [7:0] int_q_rx_data;
	wire int_q_rx_valid;
	axi4L_slave u_axi_slave(
		.ACLK(ACLK),
		.ARESETn(ARESETn),
		.AXI_AWADDR(AXI_AWADDR),
		.AXI_AWVALID(AXI_AWVALID),
		.AXI_AWREADY(AXI_AWREADY),
		.AXI_WDATA(AXI_WDATA),
		.AXI_WSTRB(AXI_WSTRB),
		.AXI_WVALID(AXI_WVALID),
		.AXI_WREADY(AXI_WREADY),
		.AXI_BRESP(AXI_BRESP),
		.AXI_BVALID(AXI_BVALID),
		.AXI_BREADY(AXI_BREADY),
		.AXI_ARADDR(AXI_ARADDR),
		.AXI_ARVALID(AXI_ARVALID),
		.AXI_ARREADY(AXI_ARREADY),
		.AXI_RDATA(AXI_RDATA),
		.AXI_RRESP(AXI_RRESP),
		.AXI_RVALID(AXI_RVALID),
		.AXI_RREADY(AXI_RREADY),
		.qspi_start(int_a_start),
		.qspi_abort(int_a_abort),
		.qspi_ctrl_cmd(int_a_ctrl_cmd),
		.qspi_addr(int_a_addr),
		.qspi_num_bytes(int_a_num_bytes),
		.qspi_busy(int_a_busy),
		.qspi_done(int_a_done),
		.qspi_error(int_a_error),
		.qspi_tx_data(int_a_tx_data),
		.qspi_tx_req(int_a_tx_req),
		.qspi_rx_data(int_a_rx_data),
		.qspi_rx_valid(int_a_rx_valid),
		.xip_cfg(int_xip_cfg)
	);
	qspi_xip_slave #(
		.XIP_BASE(XIP_BASE),
		.XIP_SIZE(XIP_SIZE)
	) u_xip_slave(
		.ACLK(ACLK),
		.ARESETn(ARESETn),
		.AXI_ARADDR(XIP_ARADDR),
		.AXI_ARVALID(XIP_ARVALID),
		.AXI_ARREADY(XIP_ARREADY),
		.AXI_RDATA(XIP_RDATA),
		.AXI_RRESP(XIP_RRESP),
		.AXI_RVALID(XIP_RVALID),
		.AXI_RREADY(XIP_RREADY),
		.xip_cfg(int_xip_cfg),
		.x_start(int_x_start),
		.x_ctrl_cmd(int_x_ctrl_cmd),
		.x_addr(int_x_addr),
		.x_num_bytes(int_x_num_bytes),
		.x_busy(int_x_busy),
		.x_done(int_x_done),
		.x_error(int_x_error),
		.x_rx_data(int_x_rx_data),
		.x_rx_valid(int_x_rx_valid)
	);
	qspi_arbiter u_arbiter(
		.ACLK(ACLK),
		.ARESETn(ARESETn),
		.a_start(int_a_start),
		.a_abort(int_a_abort),
		.a_ctrl_cmd(int_a_ctrl_cmd),
		.a_addr(int_a_addr),
		.a_num_bytes(int_a_num_bytes),
		.a_tx_data(int_a_tx_data),
		.a_busy(int_a_busy),
		.a_done(int_a_done),
		.a_error(int_a_error),
		.a_tx_req(int_a_tx_req),
		.a_rx_data(int_a_rx_data),
		.a_rx_valid(int_a_rx_valid),
		.x_start(int_x_start),
		.x_ctrl_cmd(int_x_ctrl_cmd),
		.x_addr(int_x_addr),
		.x_num_bytes(int_x_num_bytes),
		.x_busy(int_x_busy),
		.x_done(int_x_done),
		.x_error(int_x_error),
		.x_rx_data(int_x_rx_data),
		.x_rx_valid(int_x_rx_valid),
		.axi_start(int_m_start),
		.axi_abort(int_m_abort),
		.axi_ctrl_cmd(int_m_ctrl_cmd),
		.axi_addr(int_m_addr),
		.axi_num_bytes(int_m_num_bytes),
		.axi_tx_data(int_m_tx_data),
		.axi_busy(int_m_busy),
		.axi_done(int_m_done),
		.axi_error(int_m_error),
		.axi_tx_req(int_m_tx_req),
		.axi_rx_data(int_m_rx_data),
		.axi_rx_valid(int_m_rx_valid)
	);
	cdc_bridge u_cdc(
		.aclk(ACLK),
		.aclk_rstn(ARESETn),
		.qclk(qclk),
		.qclk_rst(qclk_rst),
		.axi_start(int_m_start),
		.axi_abort(int_m_abort),
		.axi_ctrl_cmd(int_m_ctrl_cmd),
		.axi_addr(int_m_addr),
		.axi_num_bytes(int_m_num_bytes),
		.axi_busy(int_m_busy),
		.axi_done(int_m_done),
		.axi_error(int_m_error),
		.axi_tx_data(int_m_tx_data),
		.axi_tx_req(int_m_tx_req),
		.axi_rx_data(int_m_rx_data),
		.axi_rx_valid(int_m_rx_valid),
		.qspi_start(int_q_start),
		.qspi_abort(int_q_abort),
		.qspi_ctrl_cmd(int_q_ctrl_cmd),
		.qspi_addr(int_q_addr),
		.qspi_num_bytes(int_q_num_bytes),
		.qspi_busy(int_q_busy),
		.qspi_done(int_q_done),
		.qspi_error(int_q_error),
		.qspi_tx_data(int_q_tx_data),
		.qspi_tx_req(int_q_tx_req),
		.qspi_rx_data(int_q_rx_data),
		.qspi_rx_valid(int_q_rx_valid)
	);
	qspi_engine #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_qspi_engine(
		.sclk(qclk),
		.sclk_rst(qclk_rst),
		.cs_n(cs_n),
		.io0_out(io0_out),
		.io0_oe(io0_oe),
		.io0_in(io0_in),
		.io1_out(io1_out),
		.io1_oe(io1_oe),
		.io1_in(io1_in),
		.io2_out(io2_out),
		.io2_oe(io2_oe),
		.io2_in(io2_in),
		.io3_out(io3_out),
		.io3_oe(io3_oe),
		.io3_in(io3_in),
		.qspi_start(int_q_start),
		.qspi_abort(int_q_abort),
		.qspi_ctrl_cmd(int_q_ctrl_cmd),
		.qspi_addr(int_q_addr),
		.qspi_num_bytes(int_q_num_bytes),
		.qspi_busy(int_q_busy),
		.qspi_done(int_q_done),
		.qspi_error(int_q_error),
		.qspi_tx_data(int_q_tx_data),
		.qspi_tx_req(int_q_tx_req),
		.qspi_rx_data(int_q_rx_data),
		.qspi_rx_valid(int_q_rx_valid)
	);
endmodule
