-- Copyright (c) 2017 Nuand LLC
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
	 use ieee.std_logic_unsigned.all;

library work;
    use work.bladerf_p.all;
    use work.fifo_readwrite_p.all;

entity rx is
    generic (
        NUM_STREAMS          : natural := 2
    );
    port (
        rx_reset               : in    std_logic;
        rx_clock               : in    std_logic;
        rx_enable              : in    std_logic;

        meta_en                : in    std_logic := '0';
        timestamp_reset        : out   std_logic := '1';
        usb_speed              : in    std_logic;
        rx_mux_sel             : in    unsigned;
        rx_overflow_led        : out   std_logic := '1';
        rx_timestamp           : in    unsigned(63 downto 0);

        -- Triggering
        trigger_arm            : in    std_logic;
        trigger_fire           : in    std_logic;
        trigger_master         : in    std_logic;
        trigger_line           : inout std_logic; -- this is not good, should be in/out/oe
        trigger_signal_sync_tb : out   std_logic;

        -- 8-bit mode
        eight_bit_mode_en      : in std_logic := '0';
        highly_packed_mode_en  : in std_logic := '0';

        -- Packet to host via FX3
        packet_en              : in    std_logic;
        packet_control         : in    packet_control_t;
        packet_ready           : out   std_logic;

        -- Samples to host via FX3
        sample_fifo_rclock     : in    std_logic;
        sample_fifo_raclr      : in    std_logic;
        sample_fifo_rreq       : in    std_logic;
        sample_fifo_rdata      : out   std_logic_vector(RX_FIFO_T_DEFAULT.rdata'range);
        sample_fifo_rempty     : out   std_logic;
        sample_fifo_rfull      : out   std_logic;
        sample_fifo_rused      : out   std_logic_vector(RX_FIFO_T_DEFAULT.rused'range);

        -- Mini expansion signals
        mini_exp               : in    std_logic_vector(1 downto 0);

        -- Metadata to host via FX3
        meta_fifo_rclock       : in    std_logic;
        meta_fifo_raclr        : in    std_logic;
        meta_fifo_rreq         : in    std_logic;
        meta_fifo_rdata        : out   std_logic_vector(META_FIFO_RX_T_DEFAULT.rdata'range);
        meta_fifo_rempty       : out   std_logic;
        meta_fifo_rfull        : out   std_logic;
        meta_fifo_rused        : out   std_logic_vector(META_FIFO_RX_T_DEFAULT.rused'range);

        -- Digital Loopback Interface
        loopback_fifo_wenabled : out   std_logic;
        loopback_fifo_wreset   : in    std_logic;
        loopback_fifo_wclock   : in    std_logic;
        loopback_fifo_wdata    : in    std_logic_vector(LOOPBACK_FIFO_T_DEFAULT.wdata'range);
        loopback_fifo_wreq     : in    std_logic;
        loopback_fifo_wfull    : out   std_logic;
        loopback_fifo_wused    : out   std_logic_vector(LOOPBACK_FIFO_T_DEFAULT.wused'range);

        -- RFFE Interface
        adc_controls           : in    sample_controls_t(0 to NUM_STREAMS-1) := (others => SAMPLE_CONTROL_DISABLE);
        adc_streams            : in    sample_streams_t(0 to NUM_STREAMS-1)  := (others => ZERO_SAMPLE);
		  
		  fft_config_data_in		  : in  std_logic_vector(31 downto 0) ;
		  fft_cfg_we_in 		  : in  std_logic;
		  fft_config_data_2bit : out std_logic_vector(1 downto 0) ; 
		  fft_config_data_4bit : out std_logic_vector(3 downto 0) ;
		  timestamp_enable : out std_logic;
		  time_tick : in std_logic
    );
end entity;

architecture arch of rx is

	component windowing_lut is
		port (
			clk          : in  std_logic  := 'X';  
			rst      : in  std_logic  := 'X';  
			enable      : in  std_logic  := 'X'; 
			data_out     : out  signed(15 downto 0)  := (others => 'X');
			fft_size : in std_logic_vector(10 downto 0) := (others => 'X')
		);
	end component windowing_lut;
	
	component cordic1 is
		port (
			clk    : in  std_logic                     := 'X';             -- clk
			areset : in  std_logic                     := 'X';             -- reset
			x      : in  std_logic_vector(15 downto 0) := (others => 'X'); -- x
			y      : in  std_logic_vector(15 downto 0) := (others => 'X'); -- y
			q      : out std_logic_vector(10 downto 0)                    -- q
		);
	end component cordic1;
	
	component cordic_40bit is
		port (
			clk    : in  std_logic                     := 'X';             -- clk
			areset : in  std_logic                     := 'X';             -- reset
			x      : in  std_logic_vector(31 downto 0) := (others => 'X'); -- x
			y      : in  std_logic_vector(31 downto 0) := (others => 'X'); -- y
			q      : out std_logic_vector(10 downto 0)                    -- q
		);
	end component cordic_40bit;
	
	component cordic_input_gen is
		port (
			rst    : in  std_logic                     := 'X';             -- clk
			clk : in  std_logic                     := 'X';             -- reset
			enable : in  std_logic                     := 'X';
			real_o      : out std_logic_vector(15 downto 0);                    -- q
			imag_o      : out std_logic_vector(15 downto 0)                     -- r
		);
	end component cordic_input_gen;
	
	component cordic_ph_out_delay is
		port (
		   clk  : in std_logic  := 'X';     
			phase_rad_in : in signed(10 downto 0)  := (others => 'X');
			phase_rad_in_2 : in signed(10 downto 0)  := (others => 'X');
			phase_rad_in_div : in signed(10 downto 0)  := (others => 'X');
			phase_rad_out : out  signed(10 downto 0)  := (others => 'X');
			phase_rad_out_2 : out  signed(10 downto 0)  := (others => 'X');
			phase_rad_out_div : out  signed(10 downto 0)  := (others => 'X')
		);
	end component cordic_ph_out_delay;
	
	component log_and_ph_conv is
		port (
		   clk  : in std_logic  := 'X';
			mag_in_div : in std_logic_vector(47 downto 0)  := (others => 'X');
			mag_in : in std_logic_vector(23 downto 0)  := (others => 'X');
			mag_in_2 : in std_logic_vector(23 downto 0)  := (others => 'X');
			mag_log_out : out std_logic_vector(15 downto 0)  := (others => 'X');
			mag_log_out_2 : out std_logic_vector(15 downto 0)  := (others => 'X');
			mag_log_out_div : out std_logic_vector(15 downto 0)  := (others => 'X');
			phase_rad_in : in signed(10 downto 0)  := (others => 'X');
			phase_rad_in_2 : in signed(10 downto 0)  := (others => 'X');
			phase_rad_in_div : in signed(10 downto 0)  := (others => 'X');
			phase_deg_out : out  signed(15 downto 0)  := (others => 'X');
			phase_deg_out_2 : out  signed(15 downto 0)  := (others => 'X');
			phase_deg_out_div : out  signed(15 downto 0)  := (others => 'X');
			en_in  : in std_logic  := 'X'; 
			en_out : out std_logic  := 'X'
		);
	end component log_and_ph_conv;
	
	component new_pipeline is
		port (
			ch1_iq_real     : in  signed(15 downto 0)  := (others => 'X');
			ch1_iq_imag     : in  signed(15 downto 0)  := (others => 'X');
			ch1_fft_real     : in  signed(15 downto 0)  := (others => 'X');
			ch1_fft_imag     : in  signed(15 downto 0)  := (others => 'X');
			ch2_iq_real     : in  signed(15 downto 0)  := (others => 'X');
			ch2_iq_imag     : in  signed(15 downto 0)  := (others => 'X');
			ch2_fft_real     : in  signed(15 downto 0)  := (others => 'X');
			ch2_fft_imag     : in  signed(15 downto 0)  := (others => 'X');
			div_fft_real     : in  signed(31 downto 0)  := (others => 'X');
			div_fft_imag     : in  signed(31 downto 0)  := (others => 'X');
			en_in          : in  std_logic  := 'X';  
			clk          : in  std_logic  := 'X';  
			mag_fft_o     : out  signed(31 downto 0)  := (others => 'X');
			mag_fft_o_2     : out  signed(31 downto 0)  := (others => 'X');
			mag_fft_o_div     : out  signed(55 downto 0)  := (others => 'X');
			en_out          : out  std_logic  := 'X';
			ch1_iq_real_o     : out  signed(15 downto 0)  := (others => 'X');
			ch1_iq_imag_o     : out  signed(15 downto 0)  := (others => 'X');
			ch2_iq_real_o     : out  signed(15 downto 0)  := (others => 'X');
			ch2_iq_imag_o     : out  signed(15 downto 0)  := (others => 'X')
		);
	end component new_pipeline;
	
	component divider_block is
		port (
			clk          : in  std_logic  := 'X';
			ch1_iq_real     : in  signed(15 downto 0)  := (others => 'X');
			ch1_iq_imag     : in  signed(15 downto 0)  := (others => 'X');
			ch2_iq_real     : in  signed(15 downto 0)  := (others => 'X');
			ch2_iq_imag     : in  signed(15 downto 0)  := (others => 'X');
			div_out_real : out  signed(31 downto 0)  := (others => 'X');
			div_out_imag : out  signed(31 downto 0)  := (others => 'X')
		);
	end component divider_block;
	
	component iq_data_delay is
		port (
			clk               : in  std_logic  := 'X';
			ch1_iq_real_i     : in  signed(15 downto 0)  := (others => 'X');
			ch1_iq_imag_i     : in  signed(15 downto 0)  := (others => 'X');
			ch2_iq_real_i     : in  signed(15 downto 0)  := (others => 'X');
			ch2_iq_imag_i     : in  signed(15 downto 0)  := (others => 'X');
			ch1_iq_real_o     : out  signed(15 downto 0)  := (others => 'X');
			ch1_iq_imag_o     : out  signed(15 downto 0)  := (others => 'X');
			ch2_iq_real_o     : out  signed(15 downto 0)  := (others => 'X');
			ch2_iq_imag_o     : out  signed(15 downto 0)  := (others => 'X');
			iq_sum_real_o     : out  signed(15 downto 0)  := (others => 'X');
			iq_sum_imag_o     : out  signed(15 downto 0)  := (others => 'X');
			sink_sop_ch1_i    : in  std_logic  := 'X';
			sink_eop_ch1_i    : in  std_logic  := 'X';
			sink_sop_ch2_i    : in  std_logic  := 'X';
			sink_eop_ch2_i    : in  std_logic  := 'X';
			sink_sop_ch1_o    : out  std_logic  := 'X';
			sink_eop_ch1_o    : out  std_logic  := 'X';
			sink_sop_ch2_o    : out  std_logic  := 'X';
			sink_eop_ch2_o    : out  std_logic  := 'X';
			en_ch1_i    : in  std_logic  := 'X';
			en_ch2_i    : in  std_logic  := 'X';
			en_ch1_o    : out  std_logic  := 'X';
			en_ch2_o    : out  std_logic  := 'X'
		);
	end component iq_data_delay;
	

	component synchronous_fifo is
	generic(
		DEPTH : integer:= 4;
		DATA_WIDTH : integer:= 128
	);
	port(
		clk : in std_logic;
		rst_n : in std_logic;
		w_en : in std_logic;
		r_en : in std_logic;
		data_in : in std_logic_vector(DATA_WIDTH-1 downto 0);
		data_out : out std_logic_vector(DATA_WIDTH-1 downto 0);
		full : out std_logic;
		empty : out std_logic;
		bingo : out std_logic
	);
	end component synchronous_fifo;


	component fft_1024 is
		port (
			clk          : in  std_logic                     := 'X';             -- clk
			reset_n      : in  std_logic                     := 'X';             -- reset_n
			sink_valid   : in  std_logic                     := 'X';             -- sink_valid
			sink_ready   : out std_logic;                                        -- sink_ready
			sink_error   : in  std_logic_vector(1 downto 0)  := (others => 'X'); -- sink_error
			sink_sop     : in  std_logic                     := 'X';             -- sink_sop
			sink_eop     : in  std_logic                     := 'X';             -- sink_eop
			sink_real    : in  std_logic_vector(15 downto 0) := (others => 'X'); -- sink_real
			sink_imag    : in  std_logic_vector(15 downto 0) := (others => 'X'); -- sink_imag
			fftpts_in    : in  std_logic_vector(10 downto 0) := (others => 'X'); -- fftpts_in
			inverse      : in  std_logic_vector(0 downto 0)  := (others => 'X'); -- inverse
			source_valid : out std_logic;                                        -- source_valid
			source_ready : in  std_logic                     := 'X';             -- source_ready
			source_error : out std_logic_vector(1 downto 0);                     -- source_error
			source_sop   : out std_logic;                                        -- source_sop
			source_eop   : out std_logic;                                        -- source_eop
			source_real  : out std_logic_vector(15 downto 0);                    -- source_real
			source_imag  : out std_logic_vector(15 downto 0);                    -- source_imag
			fftpts_out   : out std_logic_vector(10 downto 0)                     -- fftpts_out
		);
	end component fft_1024;
	
	component fft1024_32bit is
		port (
			clk          : in  std_logic                     := 'X';             -- clk
			reset_n      : in  std_logic                     := 'X';             -- reset_n
			sink_valid   : in  std_logic                     := 'X';             -- sink_valid
			sink_ready   : out std_logic;                                        -- sink_ready
			sink_error   : in  std_logic_vector(1 downto 0)  := (others => 'X'); -- sink_error
			sink_sop     : in  std_logic                     := 'X';             -- sink_sop
			sink_eop     : in  std_logic                     := 'X';             -- sink_eop
			sink_real    : in  std_logic_vector(31 downto 0) := (others => 'X'); -- sink_real
			sink_imag    : in  std_logic_vector(31 downto 0) := (others => 'X'); -- sink_imag
			fftpts_in    : in  std_logic_vector(10 downto 0) := (others => 'X'); -- fftpts_in
			inverse      : in  std_logic_vector(0 downto 0)  := (others => 'X'); -- inverse
			source_valid : out std_logic;                                        -- source_valid
			source_ready : in  std_logic                     := 'X';             -- source_ready
			source_error : out std_logic_vector(1 downto 0);                     -- source_error
			source_sop   : out std_logic;                                        -- source_sop
			source_eop   : out std_logic;                                        -- source_eop
			source_real  : out std_logic_vector(31 downto 0);                    -- source_real
			source_imag  : out std_logic_vector(31 downto 0);                    -- source_imag
			fftpts_out   : out std_logic_vector(10 downto 0)                     -- fftpts_out
		);
	end component fft1024_32bit;
	

	component fft_buffer is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(15 downto 0);
		in_imag : in signed(15 downto 0);
		out_en : out std_logic;
		out_real : out signed(15 downto 0);
		out_imag : out signed(15 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer;
	
	component fft_buffer_div is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(31 downto 0);
		in_imag : in signed(31 downto 0);
		out_en : out std_logic;
		out_real : out signed(31 downto 0);
		out_imag : out signed(31 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer_div;

	
	component fft_buffer_v5 is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(15 downto 0);
		in_imag : in signed(15 downto 0);
		out_en : out std_logic;
		out_real : out signed(15 downto 0);
		out_imag : out signed(15 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer_v5;
	
	component fft_buffer_v6 is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(15 downto 0);
		in_imag : in signed(15 downto 0);
		out_en : out std_logic;
		out_real : out signed(15 downto 0);
		out_imag : out signed(15 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer_v6;
	
	component fft_buffer_3072 is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(15 downto 0);
		in_imag : in signed(15 downto 0);
		out_en : out std_logic;
		out_real : out signed(15 downto 0);
		out_imag : out signed(15 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer_3072;
	
	component fft_buffer_parametric is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(15 downto 0);
		in_imag : in signed(15 downto 0);
		out_en : out std_logic;
		out_real : out signed(15 downto 0);
		out_imag : out signed(15 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer_parametric;
	
	component fft_buffer_parametric_v2 is
	port(
		rst : in std_logic;
		clk : in std_logic;
		enable : in std_logic;
		in_real : in signed(15 downto 0);
		in_imag : in signed(15 downto 0);
		out_en : out std_logic;
		out_real : out signed(15 downto 0);
		out_imag : out signed(15 downto 0);
		write_cnt_check : out std_logic_vector(5 downto 0);
		sink_sop : out std_logic;
		sink_eop : out std_logic;
		fft_size : in std_logic_vector(10 downto 0)
	);
	end component fft_buffer_parametric_v2;
	
	component concatenate_64_to_128 is
		port(
			clk : in std_logic;
			reset : in std_logic;
			enable : in std_logic;
			in_data : in std_logic_vector(63 downto 0);
			out_data : out std_logic_vector(127 downto 0);
			out_valid : out std_logic
		);
		end component concatenate_64_to_128;

    signal rx_packet : packet_control_t;

    -- Can be set from libbladeRF using bladerf_set_rx_mux()
    type rx_mux_mode_t is (
        RX_MUX_NORMAL,
        RX_MUX_12BIT_COUNTER,
        RX_MUX_32BIT_COUNTER,
        RX_MUX_ENTROPY,
        RX_MUX_DIGITAL_LOOPBACK
    );

    signal rx_mux_mode              : rx_mux_mode_t       := RX_MUX_NORMAL;

    signal sample_fifo              : rx_fifo_t           := RX_FIFO_T_DEFAULT;
    signal loopback_fifo            : loopback_fifo_t     := LOOPBACK_FIFO_T_DEFAULT;
    signal meta_fifo                : meta_fifo_rx_t      := META_FIFO_RX_T_DEFAULT;

    signal loopback_streams         : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
    signal loopback_enabled         : std_logic           := '0';
    signal loopback_fifo_wenabled_i : std_logic           := '0';

    signal rx_gen_mode              : std_logic;
    signal rx_gen_i                 : signed(15 downto 0);
    signal rx_gen_q                 : signed(15 downto 0);
    signal rx_gen_valid             : std_logic;

    signal mux_streams              : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);

    signal trigger_signal_out       : std_logic;
    signal trigger_signal_out_sync  : std_logic;
	 
	 signal di_en_fft  : std_logic;
	 signal di_en_fft_ch2  : std_logic;
	 signal di_en_fft_q  : std_logic;
	 signal di_en_fft_ch2_q  : std_logic;
	 signal fft_buffer_oe : std_logic;
	 signal fft_buffer_oe_ch2	 : std_logic;
	 signal fft_buffer_oe_delayed : std_logic;
	 signal 	fft_buffer_oe_ch2_delayed : std_logic;
	 signal di_re_fft  : signed(15 downto 0);
	 signal di_im_fft  : signed(15 downto 0);
	 signal di_re_fft_ch2  : signed(15 downto 0);
	 signal di_im_fft_ch2  : signed(15 downto 0);
	 signal di_re_fft_delayed  : signed(15 downto 0);
	 signal di_im_fft_delayed  : signed(15 downto 0);
	 signal di_re_fft_ch2_delayed  : signed(15 downto 0);
	 signal di_im_fft_ch2_delayed  : signed(15 downto 0);
	 signal count_enable_cnt : std_logic_vector(5 downto 0);
	 signal windowing_lut_out  : signed(15 downto 0);
	 
	 signal do_en_fft  : std_logic;
	 signal do_re_fft  : std_logic_vector(15 downto 0);
	 signal do_im_fft  : std_logic_vector(15 downto 0);
	 signal do_en_fft_ch2  : std_logic;
	 signal do_re_fft_ch2  : std_logic_vector(15 downto 0);
	 signal do_im_fft_ch2  : std_logic_vector(15 downto 0);
	 signal do_en_fft_div  : std_logic;
	 signal do_re_fft_div  : std_logic_vector(31 downto 0);
	 signal do_im_fft_div  : std_logic_vector(31 downto 0);
	 
	 signal do_en_fft_fifo_ch1  : std_logic;
	 signal do_re_fft_fifo_ch1  : signed(15 downto 0);
	 signal do_im_fft_fifo_ch1  : signed(15 downto 0);
	 
	-- signal adc_controls_fft : sample_controls_t(0 to NUM_STREAMS-1) := (others => SAMPLE_CONTROL_DISABLE);
	 signal mux_streams_fft  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 signal mux_streams_fifo_writer  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 signal mux_streams_fifo_writer_bypass  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 signal mux_streams_buffered  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 signal mux_streams_q  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 signal mux_streams_buffered_iq  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 signal mux_streams_buffered_fft  : sample_streams_t(adc_streams'range) := (others => ZERO_SAMPLE);
	 
	 signal sink_sop : std_logic;
	 signal sink_eop : std_logic;
	 signal sink_sop_ch2 : std_logic;
	 signal sink_eop_ch2 : std_logic;
	 signal sink_sop_delayed : std_logic;
	 signal sink_eop_delayed : std_logic;
	 signal sink_sop_ch2_delayed : std_logic;
	 signal sink_eop_ch2_delayed : std_logic;
	 
	 signal bingo  : std_logic;
	 
	 signal fft_config_data  : std_logic_vector(31 downto 0) ;

	 
	 signal fft_cfg_we_in_q : std_logic;
	 signal fft_cfg_we : std_logic;
	 signal enable_q : std_logic;
	 signal enable_q_ch2 : std_logic;
	 
	 
	 signal ch1_ext_buf_oe : std_logic;
	 signal ch1_ext_buf_real  : signed(15 downto 0);
	 signal ch1_ext_buf_imag  : signed(15 downto 0);
	 
	 signal ch1_del_buf_oe : std_logic;
	 signal ch1_del_buf_real  : signed(15 downto 0);
	 signal ch1_del_buf_imag  : signed(15 downto 0);
	 
	 signal ch1_del_buf_oe_1024 : std_logic;
	 signal ch1_del_buf_real_1024  : signed(15 downto 0);
	 signal ch1_del_buf_imag_1024  : signed(15 downto 0);
	 
	 signal ch1_del_buf_oe_512 : std_logic;
	 signal ch1_del_buf_real_512  : signed(15 downto 0);
	 signal ch1_del_buf_imag_512  : signed(15 downto 0);
	 
	 signal ch1_final_buf_iq_oe : std_logic;
	 signal ch1_final_buf_iq_real  : signed(15 downto 0);
	 signal ch1_final_buf_iq_imag  : signed(15 downto 0);
	 
	 signal ch1_after_fft_oe : std_logic;
	 signal ch1_after_fft_real  : signed(15 downto 0);
	 signal ch1_after_fft_imag  : signed(15 downto 0);
	 
	 signal ch1_final_buf_fft_oe : std_logic;
	 signal ch1_final_buf_fft_real  : signed(15 downto 0);
	 signal ch1_final_buf_fft_imag  : signed(15 downto 0);
	 
	 signal ch1_real_multp  : signed(31 downto 0);
	 signal ch1_imag_multp  : signed(31 downto 0);
	 
	 signal ch2_ext_buf_oe : std_logic;
	 signal ch2_ext_buf_real  : signed(15 downto 0);
	 signal ch2_ext_buf_imag  : signed(15 downto 0);
	 
	 signal ch2_del_buf_oe : std_logic;
	 signal ch2_del_buf_real  : signed(15 downto 0);
	 signal ch2_del_buf_imag  : signed(15 downto 0);
	 
	 signal ch2_del_buf_oe_1024 : std_logic;
	 signal ch2_del_buf_real_1024  : signed(15 downto 0);
	 signal ch2_del_buf_imag_1024  : signed(15 downto 0);
	 
	 signal ch2_del_buf_oe_512 : std_logic;
	 signal ch2_del_buf_real_512  : signed(15 downto 0);
	 signal ch2_del_buf_imag_512  : signed(15 downto 0);
	 
	 signal ch2_final_buf_iq_oe : std_logic;
	 signal ch2_final_buf_iq_real  : signed(15 downto 0);
	 signal ch2_final_buf_iq_imag  : signed(15 downto 0);
	 
	 signal ch2_after_fft_oe : std_logic;
	 signal ch2_after_fft_real  : signed(15 downto 0);
	 signal ch2_after_fft_imag  : signed(15 downto 0);
	 
	 signal div_after_fft_oe : std_logic;
	 signal div_after_fft_real  : signed(31 downto 0);
	 signal div_after_fft_imag  : signed(31 downto 0);
	 
	 signal ch2_final_buf_fft_oe : std_logic;
	 signal ch2_final_buf_fft_real  : signed(15 downto 0);
	 signal ch2_final_buf_fft_imag  : signed(15 downto 0);
	 
	 signal iq_sum_real_o  : signed(15 downto 0);
	 signal iq_sum_imag_o  : signed(15 downto 0);
	 
	 signal pipe_en : std_logic;
	 signal pipe_en_in : std_logic;
	 signal mag_fft_o   : signed(31 downto 0);
	 signal mag_fft_o_2   : signed(31 downto 0);
	 signal mag_fft_o_div   : signed(55 downto 0);
	 signal phase_diff_o   : signed(31 downto 0);
	 signal mag_log_o   : std_logic_vector(15 downto 0);
	 signal mag_log_o_2   : std_logic_vector(15 downto 0);
	 signal mag_log_o_div   : std_logic_vector(15 downto 0);
	 signal mag_log_o_ch2   : std_logic_vector(15 downto 0);
	 signal phase_degree_o   : signed(15 downto 0);
	 signal phase_degree_o_2   : signed(15 downto 0);
	 signal phase_degree_o_div   : signed(15 downto 0);
	 signal phase_degree_o_ch2   : signed(15 downto 0);
	 signal phase_rad_o   : signed(10 downto 0);
	 signal phase_rad_o_2   : signed(10 downto 0);
	 signal phase_rad_o_div   : signed(10 downto 0);
	 signal division_square_out : signed(79 downto 0);
	 signal div_out_real_square : signed(79 downto 0);
	 signal div_out_imag_square : signed(79 downto 0);
	 signal div_out_real : signed(31 downto 0);
	 signal div_out_imag : signed(31 downto 0);
	 
	 
	 signal test_mag_o : std_logic_vector(10 downto 0);
	 signal test_mag_o_2 : std_logic_vector(10 downto 0);
	 signal test_phase_o : std_logic_vector(10 downto 0);
	 signal test_phase_o_2 : std_logic_vector(10 downto 0);
	 signal test_phase_o_40bit : std_logic_vector(10 downto 0);
	 signal extended_phase : signed(15 downto 0);
	 
	 signal ch2_real_multp  : signed(31 downto 0);
	 signal ch2_imag_multp  : signed(31 downto 0);
	 
	 signal rx_enable_cnt_start : std_logic_vector(1 downto 0) ;
	 
	 signal wait_both_channels : std_logic;
	 signal stream_start_cnt : std_logic_vector(11 downto 0);
	 signal stream_cnt_done : std_logic;
	 signal and_cnt_bits : std_logic;
	 
	 signal sample_cnt : std_logic_vector(12 downto 0);
	 signal stream_disable_cnt : std_logic_vector(9 downto 0);
	 signal stream_disable : std_logic;
	 signal cnt_disable : std_logic;
	 
	 signal fifo_writer_out_data       : std_logic_vector(63 downto 0);
	 signal fifo_writer_out_en       : std_logic;
	 
	 signal cordic_in_real       : std_logic_vector(15 downto 0);
	 signal cordic_in_imag       : std_logic_vector(15 downto 0);
	 
	 signal ch1_pipe_iq_real  : signed(15 downto 0);
	 signal ch1_pipe_iq_imag   : signed(15 downto 0);
	 signal ch2_pipe_iq_real   : signed(15 downto 0);
	 signal ch2_pipe_iq_imag   : signed(15 downto 0);
	 
	 signal only_fft_required : std_logic;
	 signal only_iq_required : std_logic;
	 signal only_one_channel : std_logic;
	 
	 signal is_meta_dma_downcount : std_logic;
	 signal mux_streams0_data_v_q : std_logic;
	 signal mux_streams1_data_v_q : std_logic;
	 signal time_tick_high_case : std_logic;

	 
	 
	 attribute keep: boolean;
	 attribute keep of mux_streams_fifo_writer: signal is true;
	 attribute keep of mux_streams_fifo_writer_bypass: signal is true;
	 attribute keep of ch2_del_buf_imag: signal is true;
	 attribute keep of ch2_ext_buf_real: signal is true;
	 attribute keep of ch2_ext_buf_imag: signal is true;
	 attribute keep of mux_streams: signal is true;
	 attribute keep of mux_streams_fft: signal is true;
	 attribute keep of mux_streams_buffered: signal is true;
	 attribute keep of fft_config_data: signal is true;
	 attribute keep of rx_mux_mode: signal is true;
	 attribute keep of trigger_signal_out_sync: signal is true;
	 attribute keep of rx_enable_cnt_start: signal is true;
	 attribute keep of wait_both_channels: signal is true;
	 attribute keep of mux_streams_buffered_iq: signal is true;
	 attribute keep of mux_streams_buffered_fft: signal is true;
	 attribute keep of fft_buffer_oe: signal is true;
	 attribute keep of ch1_ext_buf_oe: signal is true;
	 attribute keep of ch1_del_buf_oe: signal is true;
	 attribute keep of ch1_final_buf_iq_oe: signal is true;
	 attribute keep of fft_buffer_oe_ch2	: signal is true;
	 attribute keep of ch2_ext_buf_oe: signal is true;
	 attribute keep of ch2_del_buf_oe: signal is true;
	 attribute keep of ch2_final_buf_iq_oe: signal is true;
	 attribute keep of do_en_fft: signal is true;
	 attribute keep of do_en_fft_ch2: signal is true;
	 attribute keep of stream_start_cnt: signal is true;
	 attribute keep of stream_cnt_done: signal is true;
	 attribute keep of and_cnt_bits: signal is true;
	 attribute keep of ch1_after_fft_oe: signal is true;
	 attribute keep of ch1_final_buf_fft_oe: signal is true;
	 attribute keep of sample_cnt: signal is true;
	 attribute keep of stream_disable_cnt: signal is true;
	 attribute keep of stream_disable: signal is true;
	 attribute keep of cnt_disable: signal is true;
	 attribute keep of fifo_writer_out_data: signal is true;
	 attribute keep of fifo_writer_out_en: signal is true;
	 attribute keep of pipe_en: signal is true;
	 attribute keep of mag_fft_o: signal is true;
	 attribute keep of phase_diff_o: signal is true;
	 attribute keep of test_mag_o: signal is true;
	 attribute keep of test_phase_o: signal is true;

begin

    rx_mux_mode            <= rx_mux_mode_t'val(to_integer(rx_mux_sel));
    loopback_fifo_wenabled <= loopback_fifo_wenabled_i;

    set_timestamp_reset : process(rx_clock, rx_reset)
    begin
        if( rx_reset = '1' ) then
            timestamp_reset <= '1';
        elsif( rising_edge(rx_clock) ) then
            if( meta_en = '1' ) then
                timestamp_reset <= '0';
            else
                timestamp_reset <= '1';
            end if;
        end if;
    end process;


    -- RX sample FIFO
    sample_fifo.aclr   <= sample_fifo_raclr;
    sample_fifo.wclock <= rx_clock;
    U_rx_sample_fifo : entity work.rx_fifo
        generic map (
            LPM_NUMWORDS        => 2**(sample_fifo.wused'length)
        ) port map (
            aclr                => sample_fifo.aclr,

            wrclk               => sample_fifo.wclock,
            wrreq               => sample_fifo.wreq,
            data                => sample_fifo.wdata,
            wrempty             => sample_fifo.wempty,
            wrfull              => sample_fifo.wfull,
            wrusedw             => sample_fifo.wused,

            rdclk               => sample_fifo_rclock,
            rdreq               => sample_fifo_rreq,
            q                   => sample_fifo_rdata,
            rdempty             => sample_fifo_rempty,
            rdfull              => sample_fifo_rfull,
            rdusedw             => sample_fifo_rused
        );


    -- RX meta FIFO
    meta_fifo.aclr   <= meta_fifo_raclr;
    meta_fifo.wclock <= rx_clock;
    U_rx_meta_fifo : entity work.rx_meta_fifo
        generic map (
            LPM_NUMWORDS        => 2**(meta_fifo.wused'length)
        ) port map (
            aclr                => meta_fifo.aclr,

            wrclk               => meta_fifo.wclock,
            wrreq               => meta_fifo.wreq,
            data                => meta_fifo.wdata,
            wrempty             => meta_fifo.wempty,
            wrfull              => meta_fifo.wfull,
            wrusedw             => meta_fifo.wused,

            rdclk               => meta_fifo_rclock,
            rdreq               => meta_fifo_rreq,
            q                   => meta_fifo_rdata,
            rdempty             => meta_fifo_rempty,
            rdfull              => meta_fifo_rfull,
            rdusedw             => meta_fifo_rused
        );


    -- RX loopback FIFO
    loopback_fifo.aclr   <= '1' when ( (loopback_fifo_wreset = '1') or (loopback_fifo_wenabled_i = '0') ) else '0';
    loopback_fifo.rclock <= rx_clock;

    U_rx_loopback_fifo : entity work.lb_fifo
        generic map (
            LPM_NUMWORDS        => 2**(loopback_fifo.rused'length)
        )
        port map (
            aclr                => loopback_fifo.aclr,

            wrclk               => loopback_fifo_wclock,
            wrreq               => loopback_fifo_wreq,
            data                => loopback_fifo_wdata,
            wrempty             => open,
            wrfull              => loopback_fifo_wfull,
            wrusedw             => loopback_fifo_wused,

            rdclk               => loopback_fifo.rclock,
            rdreq               => loopback_fifo.rreq,
            q                   => loopback_fifo.rdata,
            rdempty             => loopback_fifo.rempty,
            rdfull              => loopback_fifo.rfull,
            rdusedw             => loopback_fifo.rused
        );

	  concatenate_64: concatenate_64_to_128
		port map (
			clk	=> rx_clock,
			reset	=> rx_reset,
			enable	=> fifo_writer_out_en and (stream_cnt_done or only_one_channel),
			in_data	=> fifo_writer_out_data,
			out_data	=> sample_fifo.wdata,
			out_valid	=> sample_fifo.wreq
		);	

    -- Sample bridge
    U_fifo_writer : entity work.fifo_writer
        generic map (
            NUM_STREAMS           => NUM_STREAMS,
            FIFO_USEDW_WIDTH      => sample_fifo.wused'length,
            FIFO_DATA_WIDTH       => fifo_writer_out_data'length,
            META_FIFO_USEDW_WIDTH => meta_fifo.wused'length,
            META_FIFO_DATA_WIDTH  => meta_fifo.wdata'length
        )
        port map (
            clock               =>  rx_clock,
            reset               =>  rx_reset,
            enable              =>  rx_enable,

            usb_speed           =>  usb_speed,
            meta_en             =>  meta_en,
            packet_en           =>  packet_en,
            timestamp           =>  rx_timestamp,
            mini_exp            =>  mini_exp,

            fifo_full           =>  sample_fifo.wfull,
            fifo_usedw          =>  sample_fifo.wused,
            fifo_data           =>  fifo_writer_out_data,
            fifo_write          =>  fifo_writer_out_en,

            packet_control      =>  packet_control,
            packet_ready        =>  packet_ready,

            eight_bit_mode_en   => eight_bit_mode_en,
            highly_packed_mode_en => highly_packed_mode_en,

            meta_fifo_full      =>  meta_fifo.wfull,
            meta_fifo_usedw     =>  meta_fifo.wused,
            meta_fifo_data      =>  meta_fifo.wdata,
            meta_fifo_write     =>  meta_fifo.wreq,

            in_sample_controls  =>  adc_controls,
            in_samples          =>  mux_streams_fifo_writer_bypass,

            overflow_led        =>  rx_overflow_led,
            overflow_count      =>  open,
            overflow_duration   =>  x"ffff",
				is_meta_dma_downcount => is_meta_dma_downcount,
				fft_config_comb		=> fft_config_data(27 downto 24)
        );


    loopback_fifo_control : process( rx_reset, loopback_fifo.rclock )
        variable offset     : natural range 0 to loopback_fifo.rdata'length;
        variable remaining  : natural range 0 to loopback_fifo.rdata'length/16;
        variable loopdata   : std_logic_vector(loopback_fifo.rdata'range);
    begin
        if( rx_reset = '1' ) then
            loopback_enabled    <= '0';
            loopback_fifo.rreq  <= '0';
            loopback_streams    <= (others => ZERO_SAMPLE);
            remaining           := 0;
        elsif( rising_edge(loopback_fifo.rclock) ) then

            -- Is loopback enabled?
            if( rx_mux_mode = RX_MUX_DIGITAL_LOOPBACK and rx_enable = '1' ) then
                loopback_enabled    <= '1';
            else
                loopback_enabled    <= '0';
                loopback_fifo.rreq  <= '0';
                remaining           := 0;
            end if;

            -- Clear data valids
            for i in loopback_streams'range loop
                loopback_streams(i).data_v <= '0';
            end loop;

            -- Handle loopback FIFO
            if( loopback_fifo.rreq = '1' ) then
                -- We have fresh data!
                loopback_fifo.rreq <= '0';
                loopdata    := loopback_fifo.rdata;
                if( eight_bit_mode_en = '0' ) then
                    remaining := loopback_fifo.rdata'length/32;
                else
                    remaining := loopback_fifo.rdata'length/16;
                end if;
            elsif( remaining = 0 and sample_fifo.wfull = '0' and loopback_fifo.rempty = '0' ) then
                -- Read more from the FIFO if we can
                loopback_fifo.rreq <= '1';
            end if;

            -- Do the loopback
            for i in loopback_streams'range loop
                if( eight_bit_mode_en = '0' ) then
                    offset := loopdata'length - (remaining*32);
                else
                    offset := loopdata'length - (remaining*16);
                end if;

                if( adc_controls(i).enable = '1' and remaining > 0 ) then
                    if( eight_bit_mode_en = '0' ) then
                        loopback_streams(i).data_i <=
                            resize(signed(loopdata(offset+11 downto offset+0)),
                                    loopback_streams(i).data_i'length);

                        loopback_streams(i).data_q <=
                            resize(signed(loopdata(offset+27 downto offset+16)),
                                    loopback_streams(i).data_q'length);
                    else
                        loopback_streams(i).data_i <=
                            shift_left(resize(signed(loopdata(offset+7 downto offset+0)),
                                    loopback_streams(i).data_i'length), 4);

                        loopback_streams(i).data_q <=
                            shift_left(resize(signed(loopdata(offset+15 downto offset+8)),
                                    loopback_streams(i).data_q'length), 4);
                    end if;

                    loopback_streams(i).data_v <= '1';

                    -- Shift our loopdata index
                    if( remaining > 0 ) then
                        remaining := remaining - 1;
                    end if;
                end if;
            end loop;
        end if;
    end process;


    U_rx_siggen : entity work.signal_generator
        port map (
            clock           =>  rx_clock,
            reset           =>  rx_reset,
            enable          =>  rx_enable,

            mode            =>  rx_gen_mode,
            eightbit_en     => eight_bit_mode_en,

            sample_i        =>  rx_gen_i,
            sample_q        =>  rx_gen_q,
            sample_valid    =>  rx_gen_valid
        );


    rx_mux : process(rx_reset, rx_clock)
    begin
        if( rx_reset = '1' ) then
            mux_streams  <= (others => ZERO_SAMPLE);
            rx_gen_mode  <= '0';
        elsif( rising_edge(rx_clock) ) then
            case rx_mux_mode is
                when RX_MUX_NORMAL =>
                    mux_streams <= adc_streams;
                    if( trigger_signal_out_sync = '0' ) then
                        for i in mux_streams'range loop
                            mux_streams(i).data_v <= '0';
                        end loop;
                    end if;
                when RX_MUX_12BIT_COUNTER | RX_MUX_32BIT_COUNTER =>
                    for i in mux_streams'range loop
                        mux_streams(i).data_i <= rx_gen_i;
                        mux_streams(i).data_q <= rx_gen_q;
                        mux_streams(i).data_v <= rx_gen_valid;
                    end loop;

                    if( rx_mux_mode = RX_MUX_32BIT_COUNTER ) then
                        rx_gen_mode <= '1';
                    else
                        rx_gen_mode <= '0';
                    end if;
                when RX_MUX_ENTROPY =>
                    -- Not yet implemented
                    mux_streams  <= (others => ZERO_SAMPLE);
                when RX_MUX_DIGITAL_LOOPBACK =>
                    mux_streams  <= loopback_streams;
                when others =>
                    mux_streams  <= (others => ZERO_SAMPLE);
            end case;
        end if;
    end process;


    -- RX Trigger
    rxtrig : entity work.trigger(async)
        generic map (
            DEFAULT_OUTPUT  => '0'
        )
        port map (
            armed           => trigger_arm,       -- in  sl
            fired           => trigger_fire,      -- in  sl
            master          => trigger_master,    -- in  sl
            trigger_in      => trigger_line,      -- in  sl
            trigger_out     => trigger_line,      -- out sl
            signal_in       => rx_enable,         -- in  sl
            signal_out      => trigger_signal_out -- out sl
        );


    U_reset_sync_loopback : entity work.reset_synchronizer
        generic map (
            INPUT_LEVEL         => '0',
            OUTPUT_LEVEL        => '0'
        )
        port map (
            clock               =>  loopback_fifo_wclock,
            async               =>  loopback_enabled,
            sync                =>  loopback_fifo_wenabled_i
        );


    U_sync_rxtrig_signal_out : entity work.synchronizer
        generic map (
            RESET_LEVEL =>  '0'
        )
        port map (
            reset       =>  rx_reset,
            clock       =>  rx_clock,
            async       =>  trigger_signal_out,
            sync        =>  trigger_signal_out_sync
        );
        trigger_signal_sync_tb <= trigger_signal_out_sync;
		  
	wait_both_channels <= adc_controls(0).enable and adc_controls(1).enable;
			
			di_en_fft_q <= adc_controls(0).enable and mux_streams(0).data_v and (not packet_en);
			di_en_fft_ch2_q <= adc_controls(1).enable and mux_streams(1).data_v and (not packet_en);
			
			di_en_fft <= '1' when (di_en_fft_q = '1' and only_one_channel = '1') else
							 '1' when (di_en_fft_q = '1' and wait_both_channels = '1' and stream_cnt_done = '1') else
							 '0';
							 
			di_en_fft_ch2 <= '1' when (di_en_fft_ch2_q = '1' and only_one_channel = '1') else
							 '1' when (di_en_fft_ch2_q = '1' and wait_both_channels = '1' and stream_cnt_done = '1') else
							 '0';
			
			
			fft_buffer_block_ch1: fft_buffer_3072
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> di_en_fft,
				in_real	=> mux_streams(0).data_i,
				in_imag	=> mux_streams(0).data_q,
				out_en	=> fft_buffer_oe,
				out_real	=> di_re_fft,
				out_imag	=> di_im_fft,
				write_cnt_check => count_enable_cnt,
				sink_sop => sink_sop,
				sink_eop => sink_eop,
				fft_size => fft_config_data(12 downto 2)
			);
			
			fft_buffer_block_ch2: fft_buffer_3072
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> di_en_fft_ch2,
				in_real	=> mux_streams(1).data_i,
				in_imag	=> mux_streams(1).data_q,
				out_en	=> fft_buffer_oe_ch2	,
				out_real	=> di_re_fft_ch2,
				out_imag	=> di_im_fft_ch2,
				sink_sop => sink_sop_ch2,
				sink_eop => sink_eop_ch2,
				fft_size => fft_config_data(23 downto 13)
			);
			
			divider_block_i: divider_block 
		   port map(
				clk => rx_clock,
				ch1_iq_real => di_re_fft,
				ch1_iq_imag => di_im_fft,
				ch2_iq_real => di_re_fft_ch2,
				ch2_iq_imag => di_im_fft_ch2,
				div_out_real => div_out_real,
				div_out_imag => div_out_imag
		   );
			
			delay_block_i: iq_data_delay 
		   port map(
				clk => rx_clock,
				ch1_iq_real_i => di_re_fft,
				ch1_iq_imag_i => di_im_fft,
				ch2_iq_real_i => di_re_fft_ch2,
				ch2_iq_imag_i => di_im_fft_ch2,
				ch1_iq_real_o => di_re_fft_delayed,
				ch1_iq_imag_o => di_im_fft_delayed,
				ch2_iq_real_o => di_re_fft_ch2_delayed,
				ch2_iq_imag_o => di_im_fft_ch2_delayed,
				iq_sum_real_o => iq_sum_real_o,
				iq_sum_imag_o => iq_sum_imag_o,
				sink_sop_ch1_i => sink_sop,
				sink_eop_ch1_i => sink_eop,
				sink_sop_ch2_i => sink_sop_ch2,
				sink_eop_ch2_i => sink_eop_ch2,
				sink_sop_ch1_o => sink_sop_delayed,
				sink_eop_ch1_o => sink_eop_delayed,
				sink_sop_ch2_o => sink_sop_ch2_delayed,
				sink_eop_ch2_o => sink_eop_ch2_delayed,
				en_ch1_i => fft_buffer_oe,
				en_ch2_i => fft_buffer_oe_ch2	,
				en_ch1_o => fft_buffer_oe_delayed,
				en_ch2_o => fft_buffer_oe_ch2_delayed
		   );
			
			
			windowing_lut_u1: windowing_lut
			port map (
				rst	=> rx_reset,
				clk	=>  rx_clock,
				enable	=> (fft_buffer_oe_delayed or fft_buffer_oe_ch2_delayed),
				data_out	=> windowing_lut_out,
				fft_size => fft_config_data(12 downto 2)
			);
			
			ch1_real_multp <= iq_sum_real_o * windowing_lut_out when fft_config_data(27 downto 24) = "1001" else
								   iq_sum_real_o * windowing_lut_out when fft_config_data(27 downto 24) = "1010" else
									di_re_fft_delayed * windowing_lut_out;
									
			ch1_imag_multp <= iq_sum_imag_o * windowing_lut_out when fft_config_data(27 downto 24) = "1001" else
								   iq_sum_imag_o * windowing_lut_out when fft_config_data(27 downto 24) = "1010" else
									di_im_fft_delayed * windowing_lut_out;
			
			ch1_extra_buffer: fft_buffer
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> fft_buffer_oe_delayed,
				in_real	=> di_re_fft_delayed,
				in_imag	=> di_im_fft_delayed,
				out_en	=> ch1_ext_buf_oe,
				out_real	=> ch1_ext_buf_real,
				out_imag	=> ch1_ext_buf_imag,
				fft_size => fft_config_data(12 downto 2)
			);
			
			ch1_delayed_buffer: fft_buffer_parametric
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> ch1_ext_buf_oe,
				in_real	=> ch1_ext_buf_real,
				in_imag	=> ch1_ext_buf_imag,
				out_en	=> ch1_del_buf_oe,
				out_real	=> ch1_del_buf_real,
				out_imag	=> ch1_del_buf_imag,
				fft_size => fft_config_data(12 downto 2)
			);

			ch1_after_fft_buf: fft_buffer
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> do_en_fft,
				in_real	=> signed(do_re_fft),
				in_imag	=> signed(do_im_fft),
				out_en	=> ch1_after_fft_oe,
				out_real	=> ch1_after_fft_real,
				out_imag	=> ch1_after_fft_imag,
				fft_size => fft_config_data(12 downto 2)
			);
			
--			
			ch2_real_multp <= di_re_fft_ch2_delayed * windowing_lut_out;
			ch2_imag_multp <= di_im_fft_ch2_delayed * windowing_lut_out;
			
			ch2_extra_buffer: fft_buffer
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> fft_buffer_oe_ch2_delayed,
				in_real	=> di_re_fft_ch2_delayed,
				in_imag	=> di_im_fft_ch2_delayed,
				out_en	=> ch2_ext_buf_oe,
				out_real	=> ch2_ext_buf_real,
				out_imag	=> ch2_ext_buf_imag,
				fft_size => fft_config_data(23 downto 13)
			);
			
			ch2_delayed_buffer: fft_buffer_parametric
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> ch2_ext_buf_oe,
				in_real	=> ch2_ext_buf_real,
				in_imag	=> ch2_ext_buf_imag,
				out_en	=> ch2_del_buf_oe,
				out_real	=> ch2_del_buf_real,
				out_imag	=> ch2_del_buf_imag,
				fft_size => fft_config_data(23 downto 13)
			);
			
				ch2_after_fft_buf: fft_buffer
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> do_en_fft_ch2,
				in_real	=> signed(do_re_fft_ch2),
				in_imag	=> signed(do_im_fft_ch2),
				out_en	=> ch2_after_fft_oe,
				out_real	=> ch2_after_fft_real,
				out_imag	=> ch2_after_fft_imag,
				fft_size => fft_config_data(23 downto 13)
			);
			
			division_after_fft_buf: fft_buffer_div
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> do_en_fft_div,
				in_real	=> signed(do_re_fft_div),
				in_imag	=> signed(do_im_fft_div),
				out_en	=> div_after_fft_oe,
				out_real	=> div_after_fft_real,
				out_imag	=> div_after_fft_imag,
				fft_size => fft_config_data(23 downto 13)
			);
			
			
			
				custom_pipeline_i: new_pipeline 
		port map(
			ch1_iq_real => ch1_del_buf_real,
			ch1_iq_imag => ch1_del_buf_imag,
			ch1_fft_real => ch1_after_fft_real,
			ch1_fft_imag => ch1_after_fft_imag,
			ch2_iq_real => ch2_del_buf_real,
			ch2_iq_imag => ch2_del_buf_imag,
			ch2_fft_real => ch2_after_fft_real,
			ch2_fft_imag => ch2_after_fft_imag,
			div_fft_real => div_after_fft_real,
			div_fft_imag => div_after_fft_imag,
			en_in        => (ch1_del_buf_oe or ch2_del_buf_oe),
			clk      => rx_clock,
			mag_fft_o  => mag_fft_o,
			mag_fft_o_2  => mag_fft_o_2,
			mag_fft_o_div  => mag_fft_o_div,
			en_out => pipe_en_in,
			ch1_iq_real_o => ch1_pipe_iq_real,
			ch1_iq_imag_o => ch1_pipe_iq_imag,
			ch2_iq_real_o => ch2_pipe_iq_real,
			ch2_iq_imag_o => ch2_pipe_iq_imag
		);
			

			cordic_i : cordic1
		port map (
			clk    => rx_clock,    --    clk.clk
			areset => rx_reset, -- areset.reset
			x      => std_logic_vector(ch1_after_fft_real),      --      x.x
			y      => std_logic_vector(ch1_after_fft_imag),     --      y.y
			q      => test_phase_o     --      q.q
		);
		
			cordic_i_2 : cordic1
		port map (
			clk    => rx_clock,    --    clk.clk
			areset => rx_reset, -- areset.reset
			x      => std_logic_vector(ch2_after_fft_real),      --      x.x
			y      => std_logic_vector(ch2_after_fft_imag),     --      y.y
			q      => test_phase_o_2      --      q.q     --      r.r
		);
		
			cordic_i_40bit : cordic_40bit
		port map (
			clk    => rx_clock,    --    clk.clk
			areset => rx_reset, -- areset.reset
			x      => std_logic_vector(div_after_fft_real),      --      x.x
			y      => std_logic_vector(div_after_fft_imag),     --      y.y
			q      => test_phase_o_40bit     --      q.q
		);
		
		cordic_ph_delay_i: cordic_ph_out_delay 
		port map(
		   clk      => rx_clock,
			phase_rad_in => signed(test_phase_o),
			phase_rad_in_2 => signed(test_phase_o_2),
			phase_rad_in_div => signed(test_phase_o_40bit),
			phase_rad_out  => phase_rad_o,
			phase_rad_out_2  => phase_rad_o_2,
			phase_rad_out_div  => phase_rad_o_div
		);
		

		log_and_degree_i: log_and_ph_conv 
		port map(
		   clk      => rx_clock,
			mag_in_div => std_logic_vector(mag_fft_o_div(55 downto 8)),
			mag_in => std_logic_vector(mag_fft_o(23 downto 0)),
			mag_in_2 => std_logic_vector(mag_fft_o_2(23 downto 0)),
			mag_log_out => mag_log_o,
			mag_log_out_2 => mag_log_o_2,
			mag_log_out_div => mag_log_o_div,
			phase_rad_in => signed( phase_rad_o),
			phase_rad_in_2 => signed(phase_rad_o_2),
			phase_rad_in_div => signed(phase_rad_o_div),
			phase_deg_out  => phase_degree_o,
			phase_deg_out_2  => phase_degree_o_2,
			phase_deg_out_div  => phase_degree_o_div,
			en_in  => pipe_en_in,
			en_out => pipe_en
		);
		
				
			ch1_final_buffer_iq: fft_buffer_v5
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=>  pipe_en,
				in_real	=> ch1_pipe_iq_real,
				in_imag	=> ch1_pipe_iq_imag,
				out_en	=> ch1_final_buf_iq_oe,
				out_real	=> ch1_final_buf_iq_real,
				out_imag	=> ch1_final_buf_iq_imag,
				fft_size => fft_config_data(12 downto 2)
			);
			
			ch1_final_buffer_fft: fft_buffer_v6
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=>  pipe_en,
				in_real	=> signed(mag_log_o),
				in_imag	=> phase_degree_o,
				out_en	=> ch1_final_buf_fft_oe,
				out_real	=> ch1_final_buf_fft_real,
				out_imag	=> ch1_final_buf_fft_imag,
				fft_size => fft_config_data(12 downto 2)
			);
			
		
			ch2_final_buffer_iq: fft_buffer_v5
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> (pipe_en),
				in_real	=> ch2_pipe_iq_real,
				in_imag	=> ch2_pipe_iq_imag,
				out_en	=> ch2_final_buf_iq_oe,
				out_real	=> ch2_final_buf_iq_real,
				out_imag	=> ch2_final_buf_iq_imag,
				fft_size => fft_config_data(23 downto 13)
			);
			
			mag_log_o_ch2 <= mag_log_o_div when (fft_config_data(27 downto 24) = "1001" or fft_config_data(27 downto 24) = "1010") else
							     mag_log_o_2;
			phase_degree_o_ch2 <= phase_degree_o_div when (fft_config_data(27 downto 24) = "1001" or fft_config_data(27 downto 24) = "1010") else
							     phase_degree_o_2;
			
			ch2_final_buffer_fft: fft_buffer_v6
			port map (
				rst	=> rx_reset,
				clk	=> rx_clock,
				enable	=> (pipe_en),
				in_real	=> signed(mag_log_o_ch2),
				in_imag	=> phase_degree_o_ch2,
				out_en	=> ch2_final_buf_fft_oe,
				out_real	=> ch2_final_buf_fft_real,
				out_imag	=> ch2_final_buf_fft_imag,
				fft_size => fft_config_data(23 downto 13)
			);
			
			
			mux_streams_fft(0).data_i <= signed(do_re_fft);
			mux_streams_fft(0).data_q <= signed(do_im_fft);
			mux_streams_fft(0).data_v <= do_en_fft;
			mux_streams_fft(1).data_i <= signed(do_re_fft_ch2);
			mux_streams_fft(1).data_q <= signed(do_im_fft_ch2);
			mux_streams_fft(1).data_v <= do_en_fft_ch2;
			
			sample_counter_proc : process(rx_reset, rx_clock)
			begin
				if( rx_reset = '1' ) then
					sample_cnt  <= "0000000000000";
				elsif( rising_edge(rx_clock) ) then
					if (wait_both_channels = '1' and di_en_fft = '1' and sample_cnt(12) = '0') then
						sample_cnt <= sample_cnt + '1';
					elsif (sample_cnt(12) = '1' and cnt_disable = '1') then
						sample_cnt <= "0000000000000";
					else 
						sample_cnt <= sample_cnt;
					end if;
				end if;
			end process;
			
			stream_disable_counter_proc : process(rx_reset, rx_clock)
			begin
				if( rx_reset = '1' ) then
					stream_disable_cnt  <= "0000000000";
				elsif( rising_edge(rx_clock) ) then
					if (sample_cnt(12) = '1' and wait_both_channels = '1' and adc_streams(0).data_v = '1') then
						stream_disable_cnt <= stream_disable_cnt + '1';
					elsif (sample_cnt(12) = '0' and wait_both_channels = '1' and stream_disable_cnt = "1111111111") then
						stream_disable_cnt <= stream_disable_cnt + '1';
					else 
						stream_disable_cnt <= stream_disable_cnt;
					end if;
				end if;
			end process;
			
			cnt_disable <= '1' when stream_disable_cnt = "1111111111" else '0';
			stream_disable <= '1' when sample_cnt(12) = '1' else '0';
			
			stream_counter_proc : process(rx_reset, rx_clock)
			begin
				if( rx_reset = '1' ) then
					stream_start_cnt  <= "000000000000";
				elsif( rising_edge(rx_clock) ) then
					if (wait_both_channels = '1' and and_cnt_bits = '0') then
						stream_start_cnt   <= stream_start_cnt + '1';
					elsif (stream_start_cnt(11) = '1' and wait_both_channels = '0') then
						stream_start_cnt <= "000000000000";
					else 
						stream_start_cnt <= stream_start_cnt;
					end if;
				end if;
			end process;	
			
			and_cnt_bits <= stream_start_cnt(11) and stream_start_cnt(10) and stream_start_cnt(9) and stream_start_cnt(8) and stream_start_cnt(7) and stream_start_cnt(6) and stream_start_cnt(5) and stream_start_cnt(4) and stream_start_cnt(3) and stream_start_cnt(2) and stream_start_cnt(1) and stream_start_cnt(0);
			
			stream_cnt_done <= '1' when stream_start_cnt = "111111111111" else '0';
			
																			
			
			mux_streams_fifo_writer_bypass(1) <= mux_streams_fifo_writer(1) when (only_one_channel = '1' and adc_controls(1).enable = '1') else
															 mux_streams_fifo_writer(1) when (wait_both_channels = '1' and only_one_channel = '0') else
														    mux_streams(1);
			mux_streams_fifo_writer_bypass(0) <= mux_streams_fifo_writer(0) when (only_one_channel = '1' and adc_controls(0).enable = '1') else
															 mux_streams_fifo_writer(0) when (wait_both_channels = '1' and only_one_channel = '0') else
														    mux_streams(0);
			
			mux_streams_fifo_writer(1) <= mux_streams_buffered_fft(1) when mux_streams_buffered_fft(1).data_v = '1' else
													mux_streams_buffered_iq(1)	;
			mux_streams_fifo_writer(0) <= mux_streams_buffered_fft(0) when mux_streams_buffered_fft(0).data_v = '1' else
													mux_streams_buffered_iq(0)	;
			
			mux_streams_buffered_iq(0).data_i <= signed(ch1_final_buf_iq_real);
			mux_streams_buffered_iq(0).data_q <= signed(ch1_final_buf_iq_imag);
			mux_streams_buffered_iq(0).data_v <= ch1_final_buf_iq_oe and not(only_fft_required);
			mux_streams_buffered_iq(1).data_i <= signed(ch2_final_buf_iq_real);
			mux_streams_buffered_iq(1).data_q <= signed(ch2_final_buf_iq_imag);
			mux_streams_buffered_iq(1).data_v <= ch2_final_buf_iq_oe and not(only_fft_required);
			
			
			mux_streams_buffered_fft(0).data_i <= signed(ch1_final_buf_fft_real);
			mux_streams_buffered_fft(0).data_q <= signed(ch1_final_buf_fft_imag);
			mux_streams_buffered_fft(0).data_v <= ch1_final_buf_fft_oe and not(only_iq_required);
			mux_streams_buffered_fft(1).data_i <= signed(ch2_final_buf_fft_real);
			mux_streams_buffered_fft(1).data_q <= signed(ch2_final_buf_fft_imag);
			mux_streams_buffered_fft(1).data_v <= ch2_final_buf_fft_oe and not(only_iq_required);
			
				    
			data_combinations : process(rx_reset,rx_clock)
			begin
			if( rx_reset = '1' ) then
				only_fft_required <= '0';
			elsif( rising_edge(rx_clock) ) then
				if( fft_config_data(27 downto 24) = "0100" or fft_config_data(27 downto 24) = "0101" or fft_config_data(27 downto 24) = "1000" or fft_config_data(27 downto 24) = "1001") then
					only_fft_required <= '1';
				else
					only_fft_required <= '0';
				end if ;
			end if ;
			end process;
			
			
			data_combinations2: process(rx_reset,rx_clock)
			begin
			if( rx_reset = '1' ) then
				only_iq_required <= '0';
			elsif( rising_edge(rx_clock) ) then
				if( fft_config_data(27 downto 24) = "0010" or fft_config_data(27 downto 24) = "0011" or fft_config_data(27 downto 24) = "0110") then
					only_iq_required <= '1';
				else
					only_iq_required <= '0';
				end if ;
			end if ;
			end process;
			
			data_combinations3: process(rx_reset,rx_clock)
			begin
			if( rx_reset = '1' ) then
				only_one_channel <= '0';
			elsif( rising_edge(rx_clock) ) then
				if(unsigned(fft_config_data(27 downto 24)) < "0110") then
					only_one_channel <= '1';
				else 
					only_one_channel <= '0';
				end if;
			end if ;
			end process;
			
			
			mux_streams_register : process(rx_reset, rx_clock)
    begin
        if( rx_reset = '1' ) then
            mux_streams_q  <= (others => ZERO_SAMPLE);
        elsif( rising_edge(rx_clock) ) then
            mux_streams_q  <= mux_streams;
        end if;
    end process;
			

			
		fft_block_1024_ch1 : component fft_1024
		port map (
			clk          => rx_clock,          --    clk.clk
			reset_n      => not rx_reset,      --    rst.reset_n
			sink_valid   => fft_buffer_oe_delayed,   --   sink.sink_valid
		--	sink_ready   => CONNECTED_TO_sink_ready,   --       .sink_ready
		--	sink_error   => CONNECTED_TO_sink_error,   --       .sink_error
			sink_sop     => sink_sop_delayed,     --       .sink_sop
			sink_eop     => sink_eop_delayed,     --       .sink_eop
			sink_real    => std_logic_vector(ch1_real_multp(27 downto 12)),    --       .sink_real
			sink_imag    => std_logic_vector(ch1_imag_multp(27 downto 12)),    --       .sink_imag
			fftpts_in    => fft_config_data(12 downto 2),    --  fft_config_data(12 downto 2)     .fftpts_in
			inverse      => "0",      --       .inverse
			source_valid => do_en_fft, -- source.source_valid
			source_ready => '1', --       .source_ready
		--	source_error => CONNECTED_TO_source_error, --       .source_error
		--	source_sop   => CONNECTED_TO_source_sop,   --       .source_sop
		--	source_eop   => CONNECTED_TO_source_eop,   --       .source_eop
			source_real  => do_re_fft,  --       .source_real
			source_imag  => do_im_fft  --       .source_imag
		--	fftpts_out   => CONNECTED_TO_fftpts_out    --       .fftpts_out
		);
		
		
		fft_block_1024_ch2 : component fft_1024
		port map (
			clk          => rx_clock,          --    clk.clk
			reset_n      => not rx_reset,      --    rst.reset_n
			sink_valid   => fft_buffer_oe_ch2_delayed,   --   sink.sink_valid
		--	sink_ready   => CONNECTED_TO_sink_ready,   --       .sink_ready
		--	sink_error   => CONNECTED_TO_sink_error,   --       .sink_error
			sink_sop     => sink_sop_ch2_delayed,     --       .sink_sop
			sink_eop     => sink_eop_ch2_delayed,     --       .sink_eop
			sink_real    => std_logic_vector(ch2_real_multp(27 downto 12)),     --       .sink_real
			sink_imag    => std_logic_vector(ch2_imag_multp(27 downto 12)),    --       .sink_imag
			fftpts_in    => fft_config_data(23 downto 13),   -- fft_config_data(23 downto 13)          .fftpts_in
			inverse      => "0",      --       .inverse
			source_valid => do_en_fft_ch2, -- source.source_valid
			source_ready => '1', --       .source_ready
		--	source_error => CONNECTED_TO_source_error, --       .source_error
		--	source_sop   => CONNECTED_TO_source_sop,   --       .source_sop
		--	source_eop   => CONNECTED_TO_source_eop,   --       .source_eop
			source_real  => do_re_fft_ch2,  --       .source_real
			source_imag  => do_im_fft_ch2  --       .source_imag
		--	fftpts_out   => CONNECTED_TO_fftpts_out    --       .fftpts_out
		);
			
		fft_block_1024_32_bit : component fft1024_32bit
		port map (
			clk          => rx_clock,          --    clk.clk
			reset_n      => not rx_reset,      --    rst.reset_n
			sink_valid   => fft_buffer_oe_ch2_delayed,   --   sink.sink_valid
		--	sink_ready   => CONNECTED_TO_sink_ready,   --       .sink_ready
		--	sink_error   => CONNECTED_TO_sink_error,   --       .sink_error
			sink_sop     => sink_sop_ch2_delayed,     --       .sink_sop
			sink_eop     => sink_eop_ch2_delayed,     --       .sink_eop
			sink_real    => std_logic_vector(div_out_real),     --       .sink_real
			sink_imag    => std_logic_vector(div_out_imag),    --       .sink_imag
			fftpts_in    => fft_config_data(23 downto 13),   -- fft_config_data(23 downto 13)          .fftpts_in
			inverse      => "0",      --       .inverse
			source_valid => do_en_fft_div, -- source.source_valid
			source_ready => '1', --       .source_ready
		--	source_error => CONNECTED_TO_source_error, --       .source_error
		--	source_sop   => CONNECTED_TO_source_sop,   --       .source_sop
		--	source_eop   => CONNECTED_TO_source_eop,   --       .source_eop
			source_real  => do_re_fft_div,  --       .source_real
			source_imag  => do_im_fft_div  --       .source_imag
		--	fftpts_out   => CONNECTED_TO_fftpts_out    --       .fftpts_out
		);
			
			

			fft_config_write : process(rx_clock)
			begin
			if( rising_edge(rx_clock) ) then
				if( fft_cfg_we = '1' ) then
					fft_config_data <= fft_config_data_in;
				end if ;
			end if ;
			end process;
			
			time_tick_write : process(rx_clock)
			begin
			if( rx_reset = '1' ) then
				time_tick_high_case <= '0';
			elsif( rising_edge(rx_clock) ) then
				if( time_tick = '1' and meta_fifo.wreq = '1' and (adc_controls(0).enable = '1' or adc_controls(1).enable = '1')) then
					time_tick_high_case <= '1';
				end if ;
			end if ;
			end process;
			
			enable_q <= adc_controls(0).enable when rising_edge( rx_clock ) ;
			enable_q_ch2 <= adc_controls(1).enable when rising_edge( rx_clock ) ;
			fft_cfg_we <= ((adc_controls(0).enable and (not enable_q)) or (adc_controls(1).enable and (not enable_q_ch2)));
			fft_config_data_2bit <= fft_config_data(1 downto 0) when rising_edge( rx_clock ) ;
			fft_config_data_4bit <= fft_config_data(27 downto 24) when rising_edge( rx_clock ) ;
			
		--	time_tick_high_case <= '1' when (time_tick = '1' and meta_fifo.wreq = '1' and (adc_controls(0).enable = '1' or adc_controls(1).enable = '1')) else '0';
			
			mux_streams0_data_v_q <= mux_streams_fifo_writer_bypass(0).data_v when rising_edge( rx_clock ) ;
			mux_streams1_data_v_q <= mux_streams_fifo_writer_bypass(1).data_v when rising_edge( rx_clock ) ;
			
			timestamp_enable <= '1' when (fft_config_data(27 downto 24) = "0000" or fft_config_data(27 downto 24) = "0010" or fft_config_data(27 downto 24) = "0100" or fft_config_data(27 downto 24) = "0110" or fft_config_data(27 downto 24) = "1000") and time_tick_high_case = '0' and mux_streams0_data_v_q = '1' and timestamp_reset = '0' else
									  '1' when (fft_config_data(27 downto 24) = "0000" or fft_config_data(27 downto 24) = "0010" or fft_config_data(27 downto 24) = "0100" or fft_config_data(27 downto 24) = "0110" or fft_config_data(27 downto 24) = "1000") and time_tick_high_case = '1' and mux_streams_fifo_writer_bypass(0).data_v = '1' and timestamp_reset = '0' else
			                    '1' when (fft_config_data(27 downto 24) = "0001" or fft_config_data(27 downto 24) = "0101" or fft_config_data(27 downto 24) = "1001") and time_tick_high_case = '0' and mux_streams1_data_v_q = '1' and timestamp_reset = '0' else
									  '1' when (fft_config_data(27 downto 24) = "0001" or fft_config_data(27 downto 24) = "0101" or fft_config_data(27 downto 24) = "1001") and time_tick_high_case = '1' and mux_streams_fifo_writer_bypass(1).data_v = '1' and timestamp_reset = '0' else
									  '1' when fft_config_data(27 downto 24) = "0011" and time_tick_high_case = '0' and mux_streams_fifo_writer_bypass(1).data_v = '1' and timestamp_reset = '0' else
									  '1' when fft_config_data(27 downto 24) = "0011" and time_tick_high_case = '1' and mux_streams1_data_v_q = '1' and timestamp_reset = '0' else
									  '1' when (fft_config_data(27 downto 24) = "0111" or fft_config_data(27 downto 24) = "1010") and mux_streams1_data_v_q = '1' and timestamp_reset = '0' else
									  '1' when is_meta_dma_downcount = '0' and timestamp_reset = '0' else 
									  '0';

end architecture;