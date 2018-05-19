// 
// sd_card.v
//
// Copyright (c) 2014 Till Harbaum <till@harbaum.org>
// Copyright (c) 2015-2018 Sorgelig
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the Lesser GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// http://elm-chan.org/docs/mmc/mmc_e.html
//
/////////////////////////////////////////////////////////////////////////

//
// Made module syncrhronous. Total code refactoring. (Sorgelig)
//

module sd_card
(
	input         clk_sys,
	input         reset,

	// config
	input         allow_sdhc,
	output        using_sdhc,

	output [31:0] sd_lba,
	output reg    sd_rd,
	output reg    sd_wr,
	input         sd_ack,
	input         sd_ack_conf,

	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,

	// SPI interface
	input         ss,
	input         sck,
	input         mosi,
	output reg    miso
);

assign using_sdhc = sdhc & allow_sdhc;
assign sd_lba     = using_sdhc ? lba : {9'd0, lba[31:9]};

wire[31:0] OCR = { 1'b1, using_sdhc, 30'd0 };  // bit30 = 1 -> high capaciry card (sdhc) // bit31 = 0 -> card power up finished
wire [7:0] READ_DATA_TOKEN     = 8'hfe;
wire [7:0] WRITE_DATA_RESPONSE = 8'h05;

// number of bytes to wait after a command before sending the reply
localparam NCR=3;

localparam RD_STATE_IDLE       = 2'd0;
localparam RD_STATE_WAIT_IO    = 2'd1;
localparam RD_STATE_SEND_TOKEN = 2'd2;
localparam RD_STATE_SEND_DATA  = 2'd3;

localparam WR_STATE_IDLE       = 3'd0;
localparam WR_STATE_EXP_DTOKEN = 3'd1;
localparam WR_STATE_RECV_DATA  = 3'd2;
localparam WR_STATE_RECV_CRC0  = 3'd3;
localparam WR_STATE_RECV_CRC1  = 3'd4;
localparam WR_STATE_SEND_DRESP = 3'd5;
localparam WR_STATE_BUSY       = 3'd6;

sdbuf buffer
(
	.clock(clk_sys),

	.address_a(sd_buff_addr),
	.data_a(sd_buff_dout),
	.wren_a(sd_ack & sd_buff_wr),
	.q_a(sd_buff_din),

	.address_b(buffer_ptr),
	.data_b(buffer_din),
	.wren_b(buffer_wr),
	.q_b(buffer_dout)
);

sdbuf conf
(
	.clock(clk_sys),

	.address_a(sd_buff_addr),
	.data_a(sd_buff_dout),
	.wren_a(sd_ack_conf & sd_buff_wr),

	.address_b(buffer_ptr),
	.wren_b(0),
	.q_b(config_dout)
);

reg sdhc;
always @(posedge clk_sys) begin
	reg old_wr;
	old_wr <= sd_buff_wr;
	if(sd_ack_conf & ~old_wr & sd_buff_wr & (sd_buff_addr == 32)) sdhc <= sd_buff_dout[0];
end

reg [31:0] lba;
reg  [8:0] buffer_ptr;
reg  [7:0] buffer_din;
wire [7:0] buffer_dout;
wire [7:0] config_dout;
reg        buffer_wr;

always @(posedge clk_sys) begin
	reg [1:0] read_state;
	reg [2:0] write_state;
	reg [6:0] sbuf;
	reg       cmd55;
	reg [7:0] cmd;
	reg [2:0] bit_cnt;
	reg [3:0] byte_cnt;
	reg [7:0] reply;
	reg [7:0] reply0, reply1, reply2, reply3;
	reg [3:0] reply_len;
	reg       tx_finish;
	reg       rx_finish;
	reg       old_sck;
	reg       synced;
	reg [5:0] ack;
	reg       io_ack;
	reg [2:0] write_prc;
	reg [4:0] idle_cnt = 0;

	if(write_prc) begin
		write_prc <= write_prc + 1'b1;
		if(write_prc < 3) buffer_wr <= 1;
		else if(write_prc < 5) buffer_wr <= 0;
		else begin
			buffer_ptr <= buffer_ptr + 1'b1;
			write_prc <= 0;
		end
	end else buffer_wr <= 0;

	ack <= {ack[4:0], sd_ack};
	if(ack[5:4] == 2'b10) io_ack <= 1;
	if(ack[5:4] == 2'b01) {sd_rd,sd_wr} <= 0;

	old_sck <= sck;
	
	if(~ss)                              idle_cnt <= 31;
	else if(~old_sck && sck && idle_cnt) idle_cnt <= idle_cnt - 1'd1;

	if(reset || !idle_cnt) begin
		bit_cnt  <= 0;
		byte_cnt <= 15;
		synced   <= 0;
		miso   <= 1;
		sbuf     <= 7'b1111111;
		tx_finish<= 0;
		rx_finish<= 0;
		read_state  <= RD_STATE_IDLE;
		write_state <= WR_STATE_IDLE;
	end

	if(old_sck & ~sck & ~ss) begin
		tx_finish <= 0;
		miso <= 1;				// default: send 1's (busy/wait)

		if(byte_cnt == 5+NCR) begin
			miso <= reply[~bit_cnt];

			if(bit_cnt == 7) begin
				// these three commands all have a reply_len of 0 and will thus
				// not send more than a single reply byte

				// CMD9: SEND_CSD
				// CMD10: SEND_CID
				if((cmd == 'h49) | (cmd ==  'h4a))
					read_state <= RD_STATE_SEND_TOKEN;      // jump directly to data transmission
						
				// CMD17: READ_SINGLE_BLOCK
				if(cmd == 'h51) begin
					io_ack <= 0;
					read_state <= RD_STATE_WAIT_IO;         // start waiting for data from io controller
					sd_rd <= 1;                      // trigger request to io controller
				end
			end
		end
		else if((reply_len > 0) && (byte_cnt == 5+NCR+1)) miso <= reply0[~bit_cnt];
		else if((reply_len > 1) && (byte_cnt == 5+NCR+2)) miso <= reply1[~bit_cnt];
		else if((reply_len > 2) && (byte_cnt == 5+NCR+3)) miso <= reply2[~bit_cnt];
		else if((reply_len > 3) && (byte_cnt == 5+NCR+4)) miso <= reply3[~bit_cnt];
		else begin
			if(byte_cnt > 5+NCR && read_state==RD_STATE_IDLE && write_state==WR_STATE_IDLE) tx_finish <= 1;
			miso <= 1;
		end

		// ---------- read state machine processing -------------

		case(read_state)
			RD_STATE_IDLE: ; // do nothing


			// waiting for io controller to return data
			RD_STATE_WAIT_IO: begin
				if(io_ack & (bit_cnt == 7)) read_state <= RD_STATE_SEND_TOKEN;
			end

			// send data token
			RD_STATE_SEND_TOKEN: begin
				miso <= READ_DATA_TOKEN[~bit_cnt];
	
				if(bit_cnt == 7) begin
					read_state <= RD_STATE_SEND_DATA;   // next: send data
					buffer_ptr <= 0;
					if(cmd == 'h49) buffer_ptr <= 16;
				end
			end

			// send data
			RD_STATE_SEND_DATA: begin

				miso <= ((cmd == 'h49) | (cmd == 'h4A)) ? config_dout[~bit_cnt] : buffer_dout[~bit_cnt];

				if(bit_cnt == 7) begin
					// sent 512 sector data bytes?
					if((cmd == 'h51) & (&buffer_ptr[8:0])) read_state <= RD_STATE_IDLE;

					// sent 16 cid/csd data bytes?
					else if(((cmd == 'h49) | (cmd == 'h4a)) & (&buffer_ptr[3:0])) read_state <= RD_STATE_IDLE;

					else buffer_ptr <= buffer_ptr + 1'd1;    // not done yet -> trigger read of next data byte
				end
			end
		endcase

		// ------------------ write support ----------------------
		// send write data response
		if(write_state == WR_STATE_SEND_DRESP) miso <= WRITE_DATA_RESPONSE[~bit_cnt];

		// busy after write until the io controller sends ack
		if(write_state == WR_STATE_BUSY) miso <= 0;
   end

	if(~old_sck & sck & ~ss) begin

	   if(synced) bit_cnt <= bit_cnt + 1'd1;

		if((bit_cnt != 7) && (write_state==WR_STATE_EXP_DTOKEN) && ({ sbuf, mosi} == 8'hfe )) begin
			write_state <= WR_STATE_RECV_DATA;
			bit_cnt <= 0; // atchoum
		end
		// assemble byte
		else if(bit_cnt != 7) sbuf[6:0] <= { sbuf[5:0], mosi };
		else begin
			// finished reading one byte
			// byte counter runs against 15 byte boundary
			if(byte_cnt != 15) byte_cnt <= byte_cnt + 1'd1;

			// byte_cnt > 6 -> complete command received
			// first byte of valid command is 01xxxxxx
			// don't accept new commands once a write or read command has been accepted
 			if((byte_cnt > 5) & (write_state == WR_STATE_IDLE) & (read_state == RD_STATE_IDLE) && !rx_finish) begin
				byte_cnt <= 0;
				cmd <= { sbuf, mosi};

			   // set cmd55 flag if previous command was 55
			   cmd55 <= (cmd == 'h77);
			end

			// parse additional command bytes
			if(byte_cnt == 0) lba[31:24] <= { sbuf, mosi};
			if(byte_cnt == 1) lba[23:16] <= { sbuf, mosi};
			if(byte_cnt == 2) lba[15:8]  <= { sbuf, mosi};
			if(byte_cnt == 3) lba[7:0]   <= { sbuf, mosi};

			// last byte (crc) received, evaluate
			if(byte_cnt == 4) begin

				// default:
				reply <= 4;      // illegal command
				reply_len <= 0;  // no extra reply bytes
				rx_finish <= 1;

				case(cmd)
					// CMD0: GO_IDLE_STATE
					'h40: reply <= 1;    // ok, busy

					// CMD1: SEND_OP_COND
					'h41: reply <= 0;    // ok, not busy

					// CMD8: SEND_IF_COND (V2 only)
					'h48: begin
							reply  <= 1;   // ok, busy

							reply0 <= 'h00;
							reply1 <= 'h00;
							reply2 <= 'h01;
							reply3 <= 'hAA;
							reply_len <= 4;
						end

					// CMD9: SEND_CSD
					'h49: reply <= 0;    // ok

					// CMD10: SEND_CID
					'h4a: reply <= 0;    // ok

					// CMD16: SET_BLOCKLEN
					'h50: begin
							// we only support a block size of 512
							if(sd_lba == 512) reply <= 0;  // ok
								else reply <= 'h40;         // parmeter error
						end

					// CMD17: READ_SINGLE_BLOCK
					'h51: reply <= 0;    // ok

					// CMD24: WRITE_BLOCK
					'h58: begin
							reply <= 0;    // ok
							write_state <= WR_STATE_EXP_DTOKEN;  // expect data token
							rx_finish <=0;
							buffer_ptr <= 0;
						end

					// ACMD41: APP_SEND_OP_COND
					'h69: if(cmd55) reply <= 0;    // ok, not busy

					// CMD55: APP_COND
					'h77: reply <= 1;    // ok, busy

					// CMD58: READ_OCR
					'h7a: begin
							reply <= 0;    // ok

							reply0 <= OCR[31:24];   // bit 30 = 1 -> high capacity card
							reply1 <= OCR[23:16];
							reply2 <= OCR[15:8];
							reply3 <= OCR[7:0];
							reply_len <= 4;
						end

					// CMD59: CRC_ON_OFF
					'h7b: reply <= 0;    // ok
				endcase
			end

				// ---------- handle write -----------
			case(write_state)
				// do nothing in idle state
				WR_STATE_IDLE: ;

				// waiting for data token
				WR_STATE_EXP_DTOKEN:
					if({ sbuf, mosi} == 8'hfe ) write_state <= WR_STATE_RECV_DATA;

				// transfer 512 bytes
				WR_STATE_RECV_DATA: begin
					// push one byte into local buffer
					write_prc  <= 1;
					buffer_din <= {sbuf, mosi};

					// all bytes written?
					if(buffer_ptr == 511) write_state <= WR_STATE_RECV_CRC0;
				end

				// transfer 1st crc byte
				WR_STATE_RECV_CRC0:
					write_state <= WR_STATE_RECV_CRC1;

				// transfer 2nd crc byte
				WR_STATE_RECV_CRC1:
					write_state <= WR_STATE_SEND_DRESP;

				// send data response
				WR_STATE_SEND_DRESP: begin
					write_state <= WR_STATE_BUSY;
					io_ack <= 0;
					sd_wr <= 1;               // trigger write request to io ontroller
				end

				// wait for io controller to accept data
				WR_STATE_BUSY:
					if(io_ack) begin
						write_state <= WR_STATE_IDLE;
						rx_finish <= 1;
					end
			endcase
		end
		
		// wait for first 0 bit until start counting bits
		if(!synced && !mosi) begin
			synced   <= 1;
			bit_cnt  <= 1; // byte assembly prepare for next time loop
			sbuf     <= 7'b1111110; // byte assembly prepare for next time loop
			rx_finish<= 0;
		end else if (synced && tx_finish && rx_finish ) begin
			synced   <= 0;
			bit_cnt  <= 0;
			rx_finish<= 0;
		end
	end
end

endmodule

module sdbuf
(
	input	       clock,
	input	 [8:0] address_a,
	input	 [8:0] address_b,
	input	 [7:0] data_a,
	input	 [7:0] data_b,
	input	       wren_a,
	input	       wren_b,
	output [7:0] q_a,
	output [7:0] q_b
);

altsyncram	altsyncram_component (
			.clock0 (clock),
			.wren_a (wren_a),
			.address_b (address_b),
			.data_b (data_b),
			.wren_b (wren_b),
			.address_a (address_a),
			.data_a (data_a),
			.q_a (q_a),
			.q_b (q_b),
			.aclr0 (1'b0),
			.aclr1 (1'b0),
			.addressstall_a (1'b0),
			.addressstall_b (1'b0),
			.byteena_a (1'b1),
			.byteena_b (1'b1),
			.clock1 (1'b1),
			.clocken0 (1'b1),
			.clocken1 (1'b1),
			.clocken2 (1'b1),
			.clocken3 (1'b1),
			.eccstatus (),
			.rden_a (1'b1),
			.rden_b (1'b1));
defparam
	altsyncram_component.address_reg_b = "CLOCK0",
	altsyncram_component.clock_enable_input_a = "BYPASS",
	altsyncram_component.clock_enable_input_b = "BYPASS",
	altsyncram_component.clock_enable_output_a = "BYPASS",
	altsyncram_component.clock_enable_output_b = "BYPASS",
	altsyncram_component.indata_reg_b = "CLOCK0",
	altsyncram_component.intended_device_family = "Cyclone III",
	altsyncram_component.lpm_type = "altsyncram",
	altsyncram_component.numwords_a = 512,
	altsyncram_component.numwords_b = 512,
	altsyncram_component.operation_mode = "BIDIR_DUAL_PORT",
	altsyncram_component.outdata_aclr_a = "NONE",
	altsyncram_component.outdata_aclr_b = "NONE",
	altsyncram_component.outdata_reg_a = "UNREGISTERED",
	altsyncram_component.outdata_reg_b = "UNREGISTERED",
	altsyncram_component.power_up_uninitialized = "FALSE",
	altsyncram_component.read_during_write_mode_mixed_ports = "DONT_CARE",
	altsyncram_component.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
	altsyncram_component.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
	altsyncram_component.widthad_a = 9,
	altsyncram_component.widthad_b = 9,
	altsyncram_component.width_a = 8,
	altsyncram_component.width_b = 8,
	altsyncram_component.width_byteena_a = 1,
	altsyncram_component.width_byteena_b = 1,
	altsyncram_component.wrcontrol_wraddress_reg_b = "CLOCK0";


endmodule