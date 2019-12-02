library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use WORK.my_functions.all;

entity TB_RF_windowed is
end entity TB_RF_windowed;

architecture test of TB_RF_windowed is

	component RF_windowed is
		generic(N_bit:	positive := 64;	--bitwidth
				M:		positive := 5;	--number of global registers
				N:		positive := 3;	--number of registers in each IN, OUT and LOCAL section
				F:		positive := 2);	--number of windows
		port(	CLK: 		IN std_logic;	--clock
				RESET: 		IN std_logic;	--synchronous reset, active high
				ENABLE: 	IN std_logic;	--active high enable
				RD1: 		IN std_logic;	--synchronous read reg 1, active high
				RD2: 		IN std_logic;	--synchronous read reg 2, active high
				WR: 		IN std_logic;	--synchronous write, active high
				ADD_WR: 	IN std_logic_vector(log2_ceiling(3*N+M)-1 downto 0);	--writing register address 
				ADD_RD1: 	IN std_logic_vector(log2_ceiling(3*N+M)-1 downto 0);	--reading register address 1
				ADD_RD2: 	IN std_logic_vector(log2_ceiling(3*N+M)-1 downto 0);	--reading register address 2
				DATAIN: 	IN std_logic_vector(N_bit-1 downto 0);		--data to write
				OUT1: 		OUT std_logic_vector(N_bit-1 downto 0);		--data to read 1
				OUT2: 		OUT std_logic_vector(N_bit-1 downto 0);		--data to read 2
				CALL_SUB:	IN std_logic;								--high when a subroutine is called
				RETURN_SUB:	IN std_logic;								--high when a subroutine is returned
				FILL:		OUT std_logic;								--signal to MMU to require fill of registers
				SPILL:		OUT std_logic;								--signal to MMU to require spill of registers
				MEM_BUS:	INOUT std_logic_vector(N_bit-1 downto 0));	--bus to/from memory for spill and fill registers
	end component RF_windowed;

	constant clk_period: time:= 10 ns;	--clock period

	--define generic parameters
	constant N_bit: positive:= 64;
	constant M: positive:= 5;
	constant N: positive:= 3;
	constant F: positive:= 2;

	--one signal for each port
	signal CLK, RESET, ENABLE, RD1, RD2, WR, CALL_SUB, RETURN_SUB, FILL, SPILL: std_logic;
	signal ADD_RD1, ADD_RD2, ADD_WR: std_logic_vector(log2_ceiling(3*N+M)-1 downto 0);
	signal DATAIN, OUT1, OUT2, MEM_BUS: std_logic_vector(N_bit-1 downto 0);

begin

	dut: RF_windowed	--device under test
		generic map(N_bit, M, N, F)
		port map(CLK, RESET, ENABLE, RD1, RD2, WR, ADD_WR, ADD_RD1, ADD_RD2, DATAIN, OUT1, OUT2, CALL_SUB, RETURN_SUB, FILL, SPILL, MEM_BUS);
		
	clk_proc: process	--clock process
	begin
		CLK<='0';
		wait for clk_period/2;
		CLK<='1';
		wait for clk_period/2;
	end process clk_proc;
	
	stim_proc: process	--stimulus process
	begin
		--initialize
		ENABLE<='0';
		RD1<='0';
		RD2<='0';
		WR<='0';
		ADD_RD1<=(others=>'0');
		ADD_RD2<=(others=>'0');
		ADD_WR<=(others=>'0');
		DATAIN<=(others=>'0');
		CALL_SUB<='0';
		RETURN_SUB<='0';
		MEM_BUS<=(others=>'Z');
	
		--test reset
		RESET<='1';
		wait for clk_period;
		
		--test enable
		RESET<='0';
		ENABLE<='0';
		WR<='1';
		ADD_WR<=std_logic_vector(to_unsigned(1, ADD_WR'length));	--second in register
		DATAIN<=std_logic_vector(to_unsigned(1, DATAIN'length));
		wait for clk_period;
		
		--test write
		ENABLE<='1';
		wait for clk_period;
		
		ADD_WR<=std_logic_vector(to_unsigned(2*N, ADD_WR'length));	--first out register
		DATAIN<=std_logic_vector(to_unsigned(2, DATAIN'length));
		wait for clk_period;
		
		--test read 1 and 2
		WR<='0';
		RD1<='1';
		RD2<='1';
		ADD_RD1<=std_logic_vector(to_unsigned(1, ADD_RD1'length));
		ADD_RD2<=std_logic_vector(to_unsigned(2*N, ADD_RD2'length));
		wait for clk_period;
		
		--test subroutine call
		RD1<='0';
		RD2<='0';
		CALL_SUB<='1';
		wait for clk_period;
		
		--test passing of arguments
		CALL_SUB<='0';
		RD1<='1';
		ADD_RD1<=std_logic_vector(to_unsigned(0, ADD_RD1'length));	--previous first out register should become the first in register
		wait for clk_period;
	
		--test write in the second windows
		RD1<='0';
		WR<='1';
		ADD_WR<=std_logic_vector(to_unsigned(N, ADD_WR'length));	--first local register
		DATAIN<=std_logic_vector(to_unsigned(3, DATAIN'length));	--it should write in the physical register number 9
		wait for clk_period;
		
		--test spill
		WR<='0';
		CALL_SUB<='1';
		wait for clk_period;
		CALL_SUB<='0';
		wait for 2*N*clk_period;
		
		--test subtoutine return
		CALL_SUB<='0';
		RETURN_SUB<='1';
		wait for clk_period;
		
		--test write to global registers
		RETURN_SUB<='0';
		WR<='1';
		DATAIN<=std_logic_vector(to_unsigned(4, DATAIN'length));
		ADD_WR<=std_logic_vector(to_unsigned(3*N, ADD_WR'length));	--first global register
		wait for clk_period;
		
		--test fill
		WR<='0';
		RETURN_SUB<='1';
		wait for clk_period;
		RETURN_SUB<='0';
		MEM_BUS<=std_logic_vector(to_unsigned(5, MEM_BUS'length));
		wait for clk_period;
		MEM_BUS<=std_logic_vector(to_unsigned(6, MEM_BUS'length));
		wait for clk_period;
		MEM_BUS<=std_logic_vector(to_unsigned(7, MEM_BUS'length));
		wait for clk_period;
		MEM_BUS<=std_logic_vector(to_unsigned(8, MEM_BUS'length));
		wait for clk_period;
		MEM_BUS<=std_logic_vector(to_unsigned(9, MEM_BUS'length));
		wait for clk_period;
		MEM_BUS<=std_logic_vector(to_unsigned(10, MEM_BUS'length));
		wait for clk_period;
		
		MEM_BUS<=(others=>'Z');
		wait;
	end process stim_proc;

end architecture test;