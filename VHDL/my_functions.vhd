library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

package my_functions is

	--function that receives an integer greater or equal to 1 and returns its base-2 logarithm rounded up to the nearest greater (or equal) integer
	function log2_ceiling (N: positive) return natural;	
	
end package my_functions;

package body my_functions is

	function log2_ceiling (N: positive) return natural is
	begin
		return natural(ceil(log2(real(N))));
	end function log2_ceiling;

end package body my_functions;