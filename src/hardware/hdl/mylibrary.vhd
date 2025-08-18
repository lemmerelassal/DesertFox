library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_unsigned.all;

package mylibrary is



    type pc_sel_t is (PC_ENTRY_POINT, PC_PLUS_ZERO, PC_PLUS_FOUR, PC_PLUS_IMM, RS1_PLUS_IMM);
    type pc_sel_array_t is array (natural range <>) of pc_sel_t;


end package;
