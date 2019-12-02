library IEEE;
library work;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.my_functions.all;

entity RF_windowed is
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
end entity RF_windowed;

architecture behavioral of RF_windowed is

	constant N_PHYSICAL_REG: positive := M+2*N*F;	--number of physical registers
	
	subtype PHYSICAL_REG_POINTER_TYPE is std_logic_vector (log2_ceiling(N_PHYSICAL_REG)-1 downto 0);	--type that is a pointer to a physical register
	type PHYSICAL_REGS_TYPE is array (0 to N_PHYSICAL_REG-1) of std_logic_vector(N_bit-1 downto 0);		--used to instantiate the registers
	
	constant FIRST_GLOBAL_REG_POINTER: PHYSICAL_REG_POINTER_TYPE := std_logic_vector(to_unsigned(2*N*F, PHYSICAL_REG_POINTER_TYPE'length));	--pointer to the first physical global register
	constant LAST_WINDOW_POINTER: PHYSICAL_REG_POINTER_TYPE := std_logic_vector(to_unsigned(2*N*(F-1), PHYSICAL_REG_POINTER_TYPE'length));	--pointer to the first register of the last window
	constant FIRST_WINDOW_POINTER: PHYSICAL_REG_POINTER_TYPE := std_logic_vector(to_unsigned(0, PHYSICAL_REG_POINTER_TYPE'length));			--pointer to the first register od the first window

	signal CWP : PHYSICAL_REG_POINTER_TYPE;		--pointer to the first register of the current window
	signal SWP : PHYSICAL_REG_POINTER_TYPE;		--pointer to the window following the last one saved in memory / to the first window that is not saved in memory
	signal CANSAVE : std_logic;					--low when a subroutine call requires a spill of the next window, high otherwise
	signal CANRESTORE : std_logic;				--low when a subroutine return requires a fill of the previous window, high otherwise
	signal SPILLING : std_logic;				--high when the RF is busy to spilling a window
	signal FILLING : std_logic;					--high when the RF is busy to fill a window
	signal PHYSICAL_REGS : PHYSICAL_REGS_TYPE;	--physical registers
	signal count : natural range 0 to 2*N-1;	--used to count how many registers are spilled/filled

	--function that receives an external address and returns the actual address of the physical registers
	function external_to_physical_address (external_address: std_logic_vector(log2_ceiling(3*N+M)-1 downto 0); CWP: PHYSICAL_REG_POINTER_TYPE) return PHYSICAL_REG_POINTER_TYPE is
		variable offset_global: natural range 0 to M-1;
		begin
			if to_integer(unsigned(external_address))<3*N then						--it means that it is not a global register
				return std_logic_vector(unsigned(external_address)+unsigned(CWP));	--so simply add an offset to the CWP
			else																	--it menas that it is a global register
				offset_global:=to_integer(unsigned(external_address))-3*N;			--so get the number of the global register
				return std_logic_vector(unsigned(FIRST_GLOBAL_REG_POINTER)+to_unsigned(offset_global, PHYSICAL_REG_POINTER_TYPE'length));	--and add it to the pointer to the first global register
			end if;
	end function external_to_physical_address;

	--function that receives a pointer to a window and returns the pointer to the next window considering the RF as a circular buffer (except for the global registers)
	function next_window (pointer : PHYSICAL_REG_POINTER_TYPE) return PHYSICAL_REG_POINTER_TYPE is
	begin
		if pointer=LAST_WINDOW_POINTER then		--if the pointer point to the last window
			return FIRST_WINDOW_POINTER;		--then return the pointer to the first window
		else
			return std_logic_vector(unsigned(pointer)+to_unsigned(2*N, PHYSICAL_REG_POINTER_TYPE'length));	--otherwise add 2N to the value of the pointer
		end if;
	end function next_window;
	
	--function that receives a pointer to a window and returns the pointer to the previous window considering the RF as a circular buffer (except for the global registers)
	function previous_window (pointer : PHYSICAL_REG_POINTER_TYPE) return PHYSICAL_REG_POINTER_TYPE is
	begin
		if pointer=FIRST_WINDOW_POINTER then	--if the pointer point to the first window
			return LAST_WINDOW_POINTER;			--then return the pointer to the last window
		else
			return std_logic_vector(unsigned(pointer)-to_unsigned(2*N, PHYSICAL_REG_POINTER_TYPE'length));	--otherwise subtract 2N to the value of the pointer
		end if;
	end function previous_window;

begin

	CANSAVE<= '0' when SWP=next_window(CWP) else '1';	--CANSAVE is low when a further subroutine call would activate a window with data that has not yet been saved
	CANRESTORE<= '0' when SWP=CWP else '1';				--CANRESTORE is low when a furhter subroutine return would activate a window with data that has been overwritten

	SPILL<=SPILLING;	--connect the internal busy signal to the external output
	FILL<=FILLING;		--connect the internal busy signal to the external output

	register_file_proc: process(CLK)
		begin
		if rising_edge(CLK) then	--positive edge triggered
			MEM_BUS<=(others=>'Z');		--default assignment
			if RESET='1' then 			--if reset is active
				OUT1<=(others=>'0');	--clear all two outputs
				OUT2<=(others=>'0');
				SWP<=(others=>'0');		--clear SWP
				CWP<=(others=>'0');		--clear CWP
				SPILLING<='0';			--clear busy flags
				FILLING<='0';
				count<=0;				--clear count
			else 
				if SPILLING='1' then		--if the RF is busy to spilling a window
					MEM_BUS<=PHYSICAL_REGS(to_integer(unsigned(CWP))+count);	--send to the memory bus, one at a time, all the registers of the window to be spilled
					if(count=2*N-1) then	--when all the registers are spilled
						SPILLING<='0';		--clear the busy flag
						count<=0;			--and clear the count
					else
						count<=count+1;		--if the spilling is not yet completed, increase the count in order to spill the next register at the next clock cycle
					end if;
				elsif FILLING='1' then		--if the RF is busy to filling a window
					PHYSICAL_REGS(to_integer(unsigned(CWP))+count)<=MEM_BUS;	--read from the memory bus, one at a time, all the reigisters of the window to be filled
					if(count=2*N-1) then	--when all the registers are filled
						FILLING<='0';		--clear the busy flag
						count<=0;			--and clear the count
					else
						count<=count+1;		--if the filling is not yet completed, increase the count in order to fill the next register at the next clock cycle
					end if;
				elsif ENABLE='1' then		--if the RF is not busy to spill or fill a window, and it is active
					if WR='1' then																				--if write signal is high
						PHYSICAL_REGS(to_integer(unsigned(external_to_physical_address(ADD_WR, CWP))))<=DATAIN;	--write register pointed by ADD_WR with the value contained in DATAIN
					end if;
					if RD1='1' then 																			--if read signal 1 is high
						OUT1<=PHYSICAL_REGS(to_integer(unsigned(external_to_physical_address(ADD_RD1, CWP))));	--send to output 1 the value contained in the register pointed by ADD_RD1
					end if;
					if RD2='1' then 																			--if read signal 2 is high
						OUT2<=PHYSICAL_REGS(to_integer(unsigned(external_to_physical_address(ADD_RD2, CWP))));	--send to output 2 the value contained in the register pointed by ADD_RD2
					end if;
					if CALL_SUB='1' then				--if a subroutine is called
						CWP<=next_window(CWP);			--change window to the next one
						if CANSAVE='0' then				--if a spill is required
							SPILLING<='1';				--rise the corresponfing busy flag
							SWP<=next_window(SWP);		--and increase also the SWP to the next window
						end if;
					elsif RETURN_SUB='1' then			--if a subroutine is returned
						CWP<=previous_window(CWP);		--change window to the previous one
						if CANRESTORE='0' then			--if a fill is required
							FILLING<='1';				--rise the corresponding busy flag
							SWP<=previous_window(SWP);	--and decrease also the SWP to the previous window
						end if;
					end if;
				end if; 
			end if;		
		end if;
	end process register_file_proc;
	
end architecture behavioral;
