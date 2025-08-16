library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_unsigned.all;

entity cpu is
    generic (entry_point : std_logic_vector(31 downto 0) := X"80010000");

  Port (
    rst, clk : in std_logic;

    -- Instruction memory bus
    inst_width : out std_logic_vector(1 downto 0); -- "00" -> 1 byte, "01" -> 2 bytes, "10" -> 4 bytes, "11" -> invalid / 8 bytes for RV64
    inst_addr : out std_logic_vector(31 downto 0);
    inst_rdata : in std_logic_vector(31 downto 0);
    inst_re : out std_logic;
    inst_rdy : in std_logic;

    -- Data memory bus
    data_width : out std_logic_vector(1 downto 0); -- "00" -> 1 byte, "01" -> 2 bytes, "10" -> 4 bytes, "11" -> invalid / 8 bytes for RV64
    data_addr, data_wdata : out std_logic_vector(31 downto 0);
    data_rdata : in std_logic_vector(31 downto 0);
    data_re, data_we : out std_logic;
    data_rdy, data_wack : in std_logic;

    -- Register file
    registerfile_rs1, registerfile_rs2, registerfile_rd : out std_logic_vector(4 downto 0);
    registerfile_wdata_rd : out std_logic_vector(31 downto 0);
    registerfile_rdata_rs1, registerfile_rdata_rs2 : in std_logic_vector(31 downto 0);
    registerfile_we : out std_logic;

    err : out std_logic
  );
end cpu;

architecture behavioural of cpu is

    type instruction_details_t is
        record
            selected, decode_error, execution_done, use_rs1, use_rs2, use_rd, decrement_counter : std_logic;
            result, next_pc, imm : std_logic_vector(31 downto 0);

            -- mmu interface
            data_width : std_logic_vector(1 downto 0);
            data_addr, data_wdata : std_logic_vector(31 downto 0);
            data_re, data_we : std_logic;
        end record;
    constant init_instruction_details: instruction_details_t := (selected => '0', imm => (others => '0'), execution_done => '0', decode_error => '1', result => (others => '0'), next_pc => (others => '0'), use_rs1 => '0', use_rs2 => '0', use_rd => '0', decrement_counter => '0',
                                                                    data_width => "10", data_addr => (others => '0'), data_wdata => (others => '0'), data_re => '0', data_we => '0');
    type instruction_details_array_t is array (natural range <>) of instruction_details_t;
    signal instruction_details_array : instruction_details_array_t(127 downto 0) := (others => init_instruction_details);


    signal opcode, funct7 : std_logic_vector(6 downto 0);
    signal instruction, n_instruction : std_logic_vector(31 downto 0);

    signal pc, n_pc : std_logic_vector(31 downto 0);
    signal rs1, rs2, rd : std_logic_vector(4 downto 0);
    signal funct3 : std_logic_vector(2 downto 0);


    signal imm_i, imm_s, imm_b, imm_u, imm_j, imm_jalr : std_logic_vector(31 downto 0);

    constant R_TYPE         : std_logic_vector(6 downto 0) := "0110011"; -- Register/Register (ADD, ...)
    constant I_TYPE         : std_logic_vector(6 downto 0) := "0010011"; -- Register/Immediate (ADDI, ...)
    constant I_TYPE_LOAD    : std_logic_vector(6 downto 0) := "0000011";
    constant S_TYPE         : std_logic_vector(6 downto 0) := "0100011"; -- Store (SB, SH, SW)
    constant B_TYPE         : std_logic_vector(6 downto 0) := "1100011"; -- Branch
    constant U_TYPE_LUI     : std_logic_vector(6 downto 0) := "0110111"; -- LUI
    constant U_TYPE_AUIPC   : std_logic_vector(6 downto 0) := "0010111"; -- AUIPC
    constant J_TYPE_JAL     : std_logic_vector(6 downto 0) := "1101111"; -- JAL
    constant J_TYPE_JALR    : std_logic_vector(6 downto 0) := "1100111"; -- JALR
    
    type opcode_t is (OP_UNSUPPORTED_TYPE, OP_R_TYPE, OP_I_TYPE, OP_I_TYPE_LOAD, OP_S_TYPE, OP_B_TYPE, OP_U_TYPE_LUI, OP_U_TYPE_AUIPC, OP_J_TYPE_JAL, OP_J_TYPE_JALR);

    type state_t is (FETCH_INSTRUCTION, WAIT_UNTIL_RD_UNLOCKED, FETCH_RS1, FETCH_RS2, EXECUTE, WRITEBACK, INCREMENT_PC, PANIC);
    type pc_sel_t is (PC_ENTRY_POINT, PC_PLUS_ZERO, PC_PLUS_FOUR, PC_PLUS_IMM, RS1_PLUS_IMM);
    type pc_sel_array_t is array (natural range <>) of pc_sel_t;

    type word_t is array (natural range <>) of std_logic_vector(31 downto 0);


    subtype tmp is std_logic_vector(31 downto 0);
    type result_t is array(integer range 0 to 127, integer range 0 to 7) of tmp;

    signal n_pc_sel : pc_sel_t := PC_ENTRY_POINT;
    signal n_pc_sel_array: pc_sel_array_t(127 downto 0) := (others => PC_PLUS_FOUR);
    

    attribute syn_encoding : string; 
    attribute syn_encoding of state_t : type is "one-hot";
    attribute syn_encoding of pc_sel_t : type is "one-hot";

    signal state, n_state : state_t;

    signal set_instruction : std_logic;

    signal decode_error : std_logic_vector(127 downto 0) := (others => '1');
    signal use_rs1 : std_logic_vector(127 downto 0) := (others => '0');
    signal use_rs2 : std_logic_vector(127 downto 0) := (others => '0');
    signal use_rd : std_logic_vector(127 downto 0) := (others => '0');
    signal execution_done : std_logic_vector(127 downto 0) := (others => '1');
    signal dec_counter : std_logic_vector(127 downto 0) := (others => '0');
    signal dwe : std_logic_vector(127 downto 0) := (others => '0'); -- data_we
    signal selected : std_logic_vector(127 downto 0) := (others => '0');


    signal next_pc : word_t(127 downto 0) := (others => (others => '0'));
    --signal result :  result_t; --word_t(127 downto 0) := (others => (others => '0'));
    signal imm : word_t(127 downto 0) := (others => (others => '0'));
    signal wdata : word_t(127 downto 0) := (others => (others => '0'));
    signal daddr : word_t(127 downto 0) := (others => (others => '0'));

    signal state_out : std_logic_vector(2 downto 0);

    signal i_inst_addr, i_data_wdata, i_data_addr : std_logic_vector(31 downto 0);
    signal i_data_we, i_data_re : std_logic;

    component ila_0 PORT (
      clk : in std_logic;
      probe2, probe3, probe4, probe5, probe6, probe7, probe8 : in std_logic_vector(31 downto 0);
      probe0, probe9, probe10 : in std_logic;
      probe1 : in std_logic_vector(2 downto 0);
      probe11, probe12 : in std_logic_vector(127 downto 0)
    );
    end component;


    impure function DoShift (
        value : std_logic_vector(31 downto 0); 
        shamt : integer range 0 to 31;
        arithmetic_shift : boolean; 
        shleft : boolean
    ) return std_logic_vector is
        variable result : std_logic_vector(31 downto 0);
        variable appendbit : std_logic;
    begin
        if arithmetic_shift = true then
            appendbit := value(31);
        else
            appendbit := '0';
        end if;

        if shamt > 31 then
            result := (others => appendbit);
            return result;
        elsif shamt = 0 then
            return value;
        end if;

        if shleft = true then
            result := (others => '0');
            result(31 downto shamt) := value(31-shamt downto 0);
        else
            result := (others => appendbit);
            result(31-shamt downto 0) := value(31 downto shamt);
        end if;
        return result;
    end function;

    function decode_imm (
        instruction : std_logic_vector(31 downto 0)
    ) return std_logic_vector is
        variable imm : std_logic_vector(31 downto 0);
    begin
        --imm := (others => '0');
        case instruction(6 downto 0) is
            when I_TYPE | I_TYPE_LOAD =>
                -- I-type
                imm(31 downto 11) := (others => instruction(31));
                imm(10 downto 5) := instruction(30 downto 25);
                imm(4 downto 1) := instruction(24 downto 21);
                imm(0) := instruction(20);

            when S_TYPE =>
                -- S-type
                imm(31 downto 11) := (others => instruction(31));
                imm(10 downto 5) := instruction(30 downto 25);
                imm(4 downto 1) := instruction(11 downto 8);
                imm(0) := instruction(7);

            when B_TYPE =>
                -- B-type
                imm(31 downto 12) := (others => instruction(31));
                imm(11) := instruction(7);
                imm(10 downto 5) := instruction(30 downto 25);
                imm(4 downto 1) := instruction(11 downto 8);
                imm(0) := '0';

            when U_TYPE_AUIPC | U_TYPE_LUI =>
                -- U-type
                imm(31) := instruction(31);
                imm(30 downto 20) := instruction(30 downto 20);
                imm(19 downto 12) := instruction(19 downto 12);
                imm(11 downto 0) := (others => '0');

            when J_TYPE_JAL =>
                -- J-type
                imm(31 downto 20) := (others => instruction(31));
                imm(19 downto 12) := instruction(19 downto 12);
                imm(11) := instruction(20);
                imm(10 downto 5) := instruction(30 downto 25);
                imm(4 downto 1) := instruction(24 downto 21);
                imm(0) := '0';
            when J_TYPE_JALR =>
                -- JALR
                imm := (others => '0');
                imm(11 downto 0) := instruction(31 downto 20);
            when others =>
                imm := (others => '0');
        end case;
        return imm;
    end function;

    signal toggler, togglef, inbetween : std_logic;

    
component eu_s is
    generic (entry_point : std_logic_vector(31 downto 0) := X"80010000");

  Port (
    instruction, registerfile_rdata_rs1, registerfile_rdata_rs2 : in std_logic_vector(31 downto 0);
    data_wack, selected : in std_logic;
    funct3 : in std_logic_vector(2 downto 0);

    imm, daddr, wdata, result : out std_logic_vector(31 downto 0);
    use_rs1,use_rs2,use_rd, execution_done, decode_error, dwe : out std_logic
  );
end component;


component eu_lui is
    generic (entry_point : std_logic_vector(31 downto 0) := X"80010000");

  Port (
    instruction, pc, registerfile_rdata_rs1, registerfile_rdata_rs2 : in std_logic_vector(31 downto 0);
    data_wack, selected : in std_logic;
    funct3 : in std_logic_vector(2 downto 0);

    imm, daddr, wdata, result : out std_logic_vector(31 downto 0);
    use_rs1,use_rs2,use_rd, execution_done, decode_error, dwe : out std_logic
  );
end component;

component eu_auipc is
    generic (entry_point : std_logic_vector(31 downto 0) := X"80010000");

  Port (
    instruction, registerfile_rdata_rs1, registerfile_rdata_rs2, pc : in std_logic_vector(31 downto 0);
    data_wack, selected : in std_logic;
    funct3 : in std_logic_vector(2 downto 0);

    imm, daddr, wdata, result : out std_logic_vector(31 downto 0);
    use_rs1,use_rs2,use_rd, execution_done, decode_error, dwe : out std_logic
  );
end component;


component eu_i is
    generic (entry_point : std_logic_vector(31 downto 0) := X"80010000");

  Port (
    instruction, registerfile_rdata_rs1, registerfile_rdata_rs2, pc : in std_logic_vector(31 downto 0);
    data_wack, selected : in std_logic;
    funct3 : in std_logic_vector(2 downto 0);
    funct7 : in std_logic_vector(6 downto 0);

    imm, daddr, wdata, result : out std_logic_vector(31 downto 0);
    use_rs1,use_rs2,use_rd, execution_done, decode_error, dwe : out std_logic
  );
end component;


component eu_r is
    generic (entry_point : std_logic_vector(31 downto 0) := X"80010000");

  Port (
    instruction, registerfile_rdata_rs1, registerfile_rdata_rs2, pc : in std_logic_vector(31 downto 0);
    data_wack, selected : in std_logic;

    funct3 : in std_logic_vector(2 downto 0);
    funct7 : in std_logic_vector(6 downto 0);

    imm, daddr, wdata, result : out std_logic_vector(31 downto 0);
    use_rs1,use_rs2,use_rd, execution_done, decode_error, dwe : out std_logic
  );
end component;

--type dim3_t is array (0 to 127, 0 to 7, 0 to 127) of std_logic_vector(31 downto 0);
--signal result : dim3_t;
--signal result : std_logic_vector(31 downto 0);
    signal result : word_t(127 downto 0) := (others => (others => '0'));


begin

    inbetween <= toggler xor togglef;

    i_inst_addr <= pc;
    --inst_addr <= i_inst_addr;
    data_wdata <= i_data_wdata;
    data_re <= i_data_re;
    data_we <= i_data_we;
    data_addr <= i_data_addr;

    ila: ila_0 PORT MAP(
      clk => clk,
      probe0 => rst,
      probe1 => state_out,
      probe2 => pc,
      probe3 => i_inst_addr,
      probe4 => instruction,
      probe5 => instruction,
      probe6 => data_rdata,
      probe7 => i_data_wdata,
      probe8 => i_data_addr,
      probe9 => i_data_we,
      probe10 => i_data_re,
      probe11 => selected,
      probe12 => execution_done
    );



    funct7 <= instruction(31 downto 25);
    rs2 <= instruction(24 downto 20);
    rs1 <= instruction(19 downto 15);
    funct3 <= instruction(14 downto 12);
    rd <= instruction(11 downto 7);
    opcode <= instruction(6 downto 0);

    registerfile_rs1 <= rs1;
    registerfile_rs2 <= rs2;
    registerfile_rd <= rd;
    registerfile_wdata_rd <= result(to_integer(unsigned(opcode)));  --  result(to_integer(unsigned(opcode)), to_integer(unsigned(funct3), to_integer((unsigned(funct7)))));
    inst_width <= "10";

    fsm: process(state, instruction_details_array, pc, inst_rdy, opcode, decode_error, use_rd, execution_done, next_pc, result,daddr, dwe, inbetween)
    begin
        n_state <= state;
        -- n_pc <= pc;
        registerfile_we <= '0';
        set_instruction <= '0';
        inst_re <= '0';
        err <= '0';
        selected <= (others => '0');


        data_width <= (others => '0');
        i_data_addr <= (others => '0');
        i_data_wdata <= (others => '0');
        i_data_re <= '0';
        i_data_we <= '0';
        inst_addr <= pc;
        
        n_pc_sel <= PC_PLUS_ZERO;

        case state is
            when FETCH_INSTRUCTION =>
                -- n_pc <= entry_point;
                n_pc_sel <= PC_ENTRY_POINT;
                set_instruction <= '1';
                if inst_rdy = '1' then
                    inst_re <= '1';
                    n_state <= EXECUTE;
                end if;
            
            when EXECUTE =>

                data_width <= instruction_details_array(to_integer(unsigned(opcode))).data_width;
                i_data_addr <= daddr(to_integer(unsigned(opcode)));
                i_data_wdata <= wdata(to_integer(unsigned(opcode)));
                i_data_re <= instruction_details_array(to_integer(unsigned(opcode))).data_re;
                i_data_we <= dwe(to_integer(unsigned(opcode)));

                selected(to_integer(unsigned(opcode))) <= '1';

                if (execution_done(to_integer(unsigned(opcode))) = '1') then
                    -- set_instruction <= '1';
                    n_state <= FETCH_INSTRUCTION;
                    --inst_addr <= next_pc(to_integer(unsigned(opcode)));

                    --if inst_rdy = '1' then
                        -- n_pc <= next_pc(to_integer(unsigned(opcode)));
                        n_pc_sel <= n_pc_sel_array(to_integer(unsigned(opcode)));
                        registerfile_we <= use_rd(to_integer(unsigned(opcode)));

                        -- if inbetween = '0' then
                            -- inst_addr <= n_pc;
                        -- end if;
                    --end if;
                elsif decode_error(to_integer(unsigned(opcode))) = '1' then
                    n_state <= PANIC;
                end if;

            when PANIC =>
                err <= '1';
            when others =>
                n_state <= FETCH_INSTRUCTION;
        end case;
    end process;

    process(n_pc_sel, pc, instruction, registerfile_rdata_rs1)
    begin
        case n_pc_sel is
            when PC_ENTRY_POINT =>
                n_pc <= entry_point;
            when PC_PLUS_FOUR =>
                n_pc <= pc + X"00000004";
            when PC_PLUS_IMM =>
                n_pc <= pc + decode_imm(instruction);
            when RS1_PLUS_IMM =>
                n_pc <= (registerfile_rdata_rs1 + decode_imm(instruction)) and X"FFFFFFFE";
            when others => --PC_PLUS_ZERO =>
                n_pc <= pc;
        end case;
    end process;

    synchronous: process(rst, clk)
    begin
        if rst = '1' then
            state <= FETCH_INSTRUCTION;
            instruction <= (others => '0');
            pc <= entry_point;
            toggler <= '0';

        elsif rising_edge(clk) then

            toggler <= not toggler;
            pc <= n_pc;
            if set_instruction = '1' then
                instruction <= instruction;
            end if;

            state <= n_state;

        end if;
    end process;

    -- instruction <= inst_rdata;

    -- process(rst,clk)
    -- begin
    --     if rst = '1' then
    --         togglef <= '0';
            -- instruction <= (others => '0');

        -- elsif falling_edge(clk) then
        --     togglef <= toggler;
            -- instruction <= inst_rdata;

    --     end if;
    -- end process;

    eu_s_inst: eu_s PORT MAP(
        --ins
        instruction => instruction,
        registerfile_rdata_rs1 => registerfile_rdata_rs1,
        registerfile_rdata_rs2 => registerfile_rdata_rs2,
        data_wack => data_wack, funct3 => funct3, selected => selected(to_integer(unsigned(S_TYPE))),
        --outs
        
    imm => imm(to_integer(unsigned(S_TYPE))), daddr => daddr(to_integer(unsigned(S_TYPE))), wdata => wdata(to_integer(unsigned(S_TYPE))), result => result(to_integer(unsigned(S_TYPE))),
    use_rs1 => use_rs1(to_integer(unsigned(S_TYPE))),use_rs2 => use_rs2(to_integer(unsigned(S_TYPE))),use_rd => use_rd(to_integer(unsigned(S_TYPE))), execution_done => execution_done(to_integer(unsigned(S_TYPE))), decode_error => decode_error(to_integer(unsigned(S_TYPE))), dwe => dwe(to_integer(unsigned(S_TYPE)))
    );


        eu_lui_inst: eu_lui PORT MAP(
        --ins
        instruction => instruction, pc => pc,
        registerfile_rdata_rs1 => registerfile_rdata_rs1,
        registerfile_rdata_rs2 => registerfile_rdata_rs2,
        data_wack => data_wack, funct3 => funct3, selected => selected(to_integer(unsigned(U_TYPE_LUI))),
        --outs
        
    imm => imm(to_integer(unsigned(U_TYPE_LUI))), daddr => daddr(to_integer(unsigned(U_TYPE_LUI))), wdata => wdata(to_integer(unsigned(U_TYPE_LUI))), result => result(to_integer(unsigned(U_TYPE_LUI))),
    use_rs1 => use_rs1(to_integer(unsigned(U_TYPE_LUI))),use_rs2 => use_rs2(to_integer(unsigned(U_TYPE_LUI))),use_rd => use_rd(to_integer(unsigned(U_TYPE_LUI))), execution_done => execution_done(to_integer(unsigned(U_TYPE_LUI))), decode_error => decode_error(to_integer(unsigned(U_TYPE_LUI))), dwe => dwe(to_integer(unsigned(U_TYPE_LUI)))
    );

    
        eu_auipc_inst: eu_auipc PORT MAP(
        --ins
        instruction => instruction, pc=>pc,
        registerfile_rdata_rs1 => registerfile_rdata_rs1,
        registerfile_rdata_rs2 => registerfile_rdata_rs2,
        data_wack => data_wack, funct3 => funct3, selected => selected(to_integer(unsigned(U_TYPE_AUIPC))),
        --outs
        
    imm => imm(to_integer(unsigned(U_TYPE_AUIPC))), daddr => daddr(to_integer(unsigned(U_TYPE_AUIPC))), wdata => wdata(to_integer(unsigned(U_TYPE_AUIPC))), result => result(to_integer(unsigned(U_TYPE_AUIPC))),
    use_rs1 => use_rs1(to_integer(unsigned(U_TYPE_AUIPC))),use_rs2 => use_rs2(to_integer(unsigned(U_TYPE_AUIPC))),use_rd => use_rd(to_integer(unsigned(U_TYPE_AUIPC))), execution_done => execution_done(to_integer(unsigned(U_TYPE_AUIPC))), decode_error => decode_error(to_integer(unsigned(U_TYPE_AUIPC))), dwe => dwe(to_integer(unsigned(U_TYPE_AUIPC)))
    );

    -- decode_store: process(instruction, pc, registerfile_rdata_rs1, registerfile_rdata_rs2, data_wack, funct3, selected(to_integer(unsigned(S_TYPE))))
    -- begin
    --     imm(to_integer(unsigned(S_TYPE))) <= decode_imm(instruction);
    --     for i in 0 to 7 loop
    --         result(to_integer(unsigned(S_TYPE))) <= decode_imm(instruction);
    --     end loop;
    --     use_rs1(to_integer(unsigned(S_TYPE))) <= '1';
    --     use_rs2(to_integer(unsigned(S_TYPE))) <= '1';
    --     -- next_pc(to_integer(unsigned(S_TYPE))) <= pc + X"00000004";
    --     execution_done(to_integer(unsigned(S_TYPE))) <= data_wack;
    --     decode_error(to_integer(unsigned(S_TYPE))) <= '0';

    --     daddr(to_integer(unsigned(S_TYPE))) <= registerfile_rdata_rs1 + decode_imm(instruction);
    --     wdata(to_integer(unsigned(S_TYPE)))<= registerfile_rdata_rs2;
    --     dwe(to_integer(unsigned(S_TYPE))) <= selected(to_integer(unsigned(S_TYPE)));
    --     instruction_details_array(to_integer(unsigned(S_TYPE))).data_width <= funct3(1 downto 0);
    -- end process;

    



    decode_load: process(instruction, pc, registerfile_rdata_rs1, data_rdy, data_rdata, funct3)
    begin
        imm(to_integer(unsigned(I_TYPE_LOAD))) <= decode_imm(instruction);
        use_rs1(to_integer(unsigned(I_TYPE_LOAD))) <= '1';
        use_rd(to_integer(unsigned(I_TYPE_LOAD))) <= '1';

        -- next_pc(to_integer(unsigned(I_TYPE_LOAD))) <= pc + X"00000004";
        execution_done(to_integer(unsigned(I_TYPE_LOAD))) <= data_rdy;
        decode_error(to_integer(unsigned(I_TYPE_LOAD))) <= '0';

        daddr(to_integer(unsigned(I_TYPE_LOAD))) <= registerfile_rdata_rs1 + decode_imm(instruction);
        instruction_details_array(to_integer(unsigned(I_TYPE_LOAD))).data_re <= '1';

            result(to_integer(unsigned(I_TYPE_LOAD))) <= data_rdata;

        instruction_details_array(to_integer(unsigned(I_TYPE_LOAD))).data_width <= funct3(1 downto 0);


        -- if(funct3(2) = '0') then
            -- case funct3(1 downto 0) is
                -- when "00" =>
                    result(to_integer(unsigned(I_TYPE_LOAD)))(31 downto 8) <= (others => data_rdata(7));

                -- when "01" =>
                    result(to_integer(unsigned(I_TYPE_LOAD)))(31 downto 16) <= (others => data_rdata(15));

                -- when "11" =>
                    decode_error(to_integer(unsigned(I_TYPE_LOAD))) <= '1';

                -- when others =>

            -- end case;
        -- end if;

    end process;

    -- execution_done(55) <= '1';
    -- decode_lui: process(instruction, pc)
    -- begin
    --     imm(to_integer(unsigned(U_TYPE_LUI))) <= decode_imm(instruction);
    --     for i in 0 to 7 loop
    --         result(to_integer(unsigned(U_TYPE_LUI))) <= decode_imm(instruction);
    --     end loop;
    --     use_rd(to_integer(unsigned(U_TYPE_LUI))) <= '1';
    --     decode_error(to_integer(unsigned(U_TYPE_LUI))) <= '0';
    -- end process;

    -- execution_done(23) <= '1';
    -- decode_auipc: process(instruction, pc)
    -- begin
    --     imm(to_integer(unsigned(U_TYPE_AUIPC))) <= decode_imm(instruction);
    --     use_rd(to_integer(unsigned(U_TYPE_AUIPC))) <= '1';
    --     for i in 0 to 7 loop
    --         result(to_integer(unsigned(U_TYPE_AUIPC))) <= pc + decode_imm(instruction);
    --     end loop;
    --     -- next_pc(to_integer(unsigned(U_TYPE_AUIPC))) <= pc + X"00000004";
    --     --execution_done(to_integer(unsigned(U_TYPE_AUIPC))) <= '1';
    --     decode_error(to_integer(unsigned(U_TYPE_AUIPC))) <= '0';
    -- end process;

    execution_done(111) <= '1';
    decode_jal: process(instruction, pc)
    begin
        imm(to_integer(unsigned(J_TYPE_JAL))) <= decode_imm(instruction);
        use_rd(to_integer(unsigned(J_TYPE_JAL))) <= '1';

        for i in 0 to 7 loop
            result(to_integer(unsigned(J_TYPE_JAL))) <= pc + X"00000004";
        end loop;

        n_pc_sel_array(to_integer(unsigned(J_TYPE_JAL))) <= PC_PLUS_IMM;
        -- next_pc(to_integer(unsigned(J_TYPE_JAL))) <= pc + decode_imm(instruction);
        --execution_done(to_integer(unsigned(J_TYPE_JAL))) <= '1';
        decode_error(to_integer(unsigned(J_TYPE_JAL))) <= '0';
    end process;

    execution_done(103) <= '1';
    decode_jalr: process(registerfile_rdata_rs1, pc, instruction)
    begin
        imm(to_integer(unsigned(J_TYPE_JALR))) <= decode_imm(instruction);
        use_rd(to_integer(unsigned(J_TYPE_JALR))) <= '1';
        use_rs1(to_integer(unsigned(J_TYPE_JALR))) <= '1';
        for i in 0 to 7 loop
            result(to_integer(unsigned(J_TYPE_JALR))) <= pc + X"00000004";
        end loop;
        n_pc_sel_array(to_integer(unsigned(J_TYPE_JALR))) <= RS1_PLUS_IMM;
        -- next_pc(to_integer(unsigned(J_TYPE_JALR))) <= (decode_imm(instruction) + registerfile_rdata_rs1) and X"FFFFFFFE"; --(pc + registerfile_rdata_rs1) and X"FFFFFFFE";
        --execution_done(to_integer(unsigned(J_TYPE_JALR))) <= '1';
        decode_error(to_integer(unsigned(J_TYPE_JALR))) <= '0';
    end process;

    execution_done(99) <= '1';
    decode_b_type: process(funct3, registerfile_rdata_rs1, registerfile_rdata_rs2, instruction, pc)
    begin
        imm(to_integer(unsigned(B_TYPE))) <= decode_imm(instruction);

        for i in 0 to 7 loop
            result(to_integer(unsigned(B_TYPE))) <= (others => '0');
        end loop;
        use_rs1(to_integer(unsigned(B_TYPE))) <= '1';
        use_rs2(to_integer(unsigned(B_TYPE))) <= '1';
        -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + X"00000004";
        n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_FOUR;

        decode_error(to_integer(unsigned(B_TYPE))) <= '0';
        --execution_done(to_integer(unsigned(B_TYPE))) <= '1';

        case funct3 is
            when "000" => -- BEQ
                if signed(registerfile_rdata_rs1) = signed(registerfile_rdata_rs2) then
                    n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_IMM; -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + decode_imm(instruction);
                end if;
            when "001" => -- BNE
                if signed(registerfile_rdata_rs1) /= signed(registerfile_rdata_rs2) then
                    n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_IMM; -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + decode_imm(instruction);
                end if;
            when "100" => -- BLT
                if signed(registerfile_rdata_rs1) < signed(registerfile_rdata_rs2) then
                    n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_IMM; -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + decode_imm(instruction);
                end if;
            when "101" => -- BGE
                if signed(registerfile_rdata_rs1) >= signed(registerfile_rdata_rs2) then
                    n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_IMM; -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + decode_imm(instruction);
                end if;
            when "110" => -- BLTU
                if unsigned(registerfile_rdata_rs1) < unsigned(registerfile_rdata_rs2) then
                    n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_IMM; -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + decode_imm(instruction);
                end if;
            when "111" => -- BGEU
                if unsigned(registerfile_rdata_rs1) >= unsigned(registerfile_rdata_rs2) then
                    n_pc_sel_array(to_integer(unsigned(B_TYPE))) <= PC_PLUS_IMM; -- next_pc(to_integer(unsigned(B_TYPE))) <= pc + decode_imm(instruction);
                end if;
            when others =>
                decode_error(to_integer(unsigned(B_TYPE))) <= '1';
        end case;
    end process;

        eu_r_inst: eu_r PORT MAP(
        --ins
        instruction => instruction, pc=>pc,
        registerfile_rdata_rs1 => registerfile_rdata_rs1,
        registerfile_rdata_rs2 => registerfile_rdata_rs2,
        data_wack => data_wack, funct3 => funct3, funct7 => funct7, selected => selected(to_integer(unsigned(R_TYPE))),
        --outs
        
    imm => imm(to_integer(unsigned(R_TYPE))), daddr => daddr(to_integer(unsigned(R_TYPE))), wdata => wdata(to_integer(unsigned(R_TYPE))), result => result(to_integer(unsigned(R_TYPE))),
    use_rs1 => use_rs1(to_integer(unsigned(R_TYPE))),use_rs2 => use_rs2(to_integer(unsigned(R_TYPE))),use_rd => use_rd(to_integer(unsigned(R_TYPE))), execution_done => execution_done(to_integer(unsigned(R_TYPE))), decode_error => decode_error(to_integer(unsigned(R_TYPE))), dwe => dwe(to_integer(unsigned(R_TYPE)))
    );

    
        eu_i_inst: eu_i PORT MAP(
        --ins
        instruction => instruction, pc=>pc,
        registerfile_rdata_rs1 => registerfile_rdata_rs1,
        registerfile_rdata_rs2 => registerfile_rdata_rs2,
        data_wack => data_wack, funct3 => funct3, funct7 => funct7, selected => selected(to_integer(unsigned(I_TYPE))),
        --outs
        
    imm => imm(to_integer(unsigned(I_TYPE))), daddr => daddr(to_integer(unsigned(I_TYPE))), wdata => wdata(to_integer(unsigned(I_TYPE))), result => result(to_integer(unsigned(I_TYPE))),
    use_rs1 => use_rs1(to_integer(unsigned(I_TYPE))),use_rs2 => use_rs2(to_integer(unsigned(I_TYPE))),use_rd => use_rd(to_integer(unsigned(I_TYPE))), execution_done => execution_done(to_integer(unsigned(I_TYPE))), decode_error => decode_error(to_integer(unsigned(I_TYPE))), dwe => dwe(to_integer(unsigned(I_TYPE)))
    );


end behavioural;