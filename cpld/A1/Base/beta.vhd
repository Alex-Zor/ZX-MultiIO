-- Aleksandr Hrytsevskyi
--------------------------
--			Alex Zor			--
--------------------------
-- Date:				12 May 2025 
-- Design Name:	ZX multiIO
-- Version:			BASE for PCB A1
-- Description:	NemoIDE, BDI, FDC, RTC controller

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity beta is
	port (
		Ah				: in std_logic_vector(15 downto 7);
		Al				: in std_logic_vector(5 downto 0);
		D				: inout std_logic_vector(7 downto 0);
		MREQ			: in std_logic;
		M1				: in std_logic;
		IORQ			: in std_logic;
		WR				: in std_logic;
		RD				: in std_logic;
		RESET			: in std_logic;
		NMI			: out std_logic := 'Z';
		A15ROM		: out std_logic;
		A14ROM		: in std_logic;
		
		BT_MAGIC,							-- magic button		
		BT_IDE,								-- setting jumpers
		BT_ZPAGE,							-- start in zero page ROM
		BT_DOS,								-- BDI enable
		BT_SD			: in std_logic;	-- SD card enable (z-controller)
		
		VG_RES,								-- MB8877(1818VG93) signals
		VG_HLT,
		VG_CS,		
		VG_CLK,
		VG_RAWR,
		VG_RSLK		: out std_logic;
		
		VG_SR,
		VG_SL,
		VG_TR43,
		VG_WD,
		VG_WFDE,
		VG_IRQ,
		VG_DRQ		: in std_logic;	
		
		FD_DSEL0,							-- FDI signals
		FD_DSEL1,
		FD_SIDE,
		FD_WRD		: out std_logic;
		FD_RDD		: in std_logic;
		
		IDE_IOW		: out std_logic;	-- IDE write
						
		IDE_HD		: inout std_logic_vector(15 downto 8);	-- IDE most significant byte
		
		BF_IOR,								-- 74lvc245 controll
		BF_EBL		: out std_logic;	
		
		RTC_DS,								-- RTC control
		RTC_RW,
		RTC_AS,
		RTC_CS		: out std_logic;
		
		SD_MISO		: in std_logic;	-- SD card
		SD_MOSI,
		SD_CLK,
		SD_CS			: out std_logic;
				
		IORQGE		: out std_logic;	-- IORQ block
		CLKIN			: in std_logic		-- 8MHz input
	);
end beta;

architecture bdi of beta is

signal A				: std_logic_vector(15 downto 0);
signal iowr			: std_logic;

-- BDI --
signal frq4			: std_logic;
signal betasel		: std_logic;
signal magicrq		: std_logic;
signal wrdreg		: std_logic_vector(3 downto 0);
signal ot_0			: std_logic;
signal ot_1			: std_logic;
signal cnt			: std_logic_vector(3 downto 0);
signal idrq			: std_logic;
signal rom48		: std_logic;

-- IDE --
signal ebl			: std_logic;
signal iow			: std_logic;
signal wrh			: std_logic;
signal ior			: std_logic;
signal rdh			: std_logic;
signal wrbf			: std_logic_vector(7 downto 0);		-- IDE write buffer
signal rdbf			: std_logic_vector(7 downto 0);		-- IDE read buffer

-- SD --
type transStates is (
		IDLE, -- Wait for SD card request
		SAMPLE, -- As there is an I/O request, prepare the transmission; sample the CPU databus if required
		TRANSMIT); -- Transmission (SEND or RECEIVE)
signal transState : transStates := IDLE; -- Transmission state (initially IDLE)
	
signal TState : unsigned(3 downto 0) := (others => '0');		-- Counts the T-States during transmission

signal fromSD 		: std_logic_vector(7 downto 0) := (others => '1');	-- Byte received from SD
signal toSD 		: std_logic_vector(7 downto 0) := (others => '1');	-- Byte to send to SD
signal toCPU		: std_logic_vector(7 downto 0) := (others => '1');
signal port_57		: std_logic;
signal port_77		: std_logic;
signal sdstatus	: std_logic;
signal sdread		: std_logic;
signal sdports		: std_logic;

--RTC--
--signal rtcports	: std_logic;

----------------------------------------------------------------------------------------------------------------------------------------------------
begin

A(15 downto 0) <= Ah(15 downto 7) & Al(4) & Al(5 downto 0); -- A4 & A6 external logic

IORQGE <= '1' when (betasel = '0' and A(0) = '1' and A(1) = '1')  or ebl = '0' or sdports = '0' else '0';

-------------------FDC---------------------------------------

process (CLKIN)
begin
	if falling_edge(CLKIN) then
		frq4 <= not frq4;
	end if;
end process;


process (RESET, MREQ) -- ROM page selector		
 begin
	if RESET = '0' then
		betasel <= BT_ZPAGE or BT_DOS;
		magicrq <= '0';
	elsif falling_edge(MREQ) then
		if M1 = '0' and BT_DOS = '0' then
			if (A(15 downto 8) = "00111101" or magicrq = '1') and rom48 = '1' then		-- map 3DXX
				betasel <= '0';
				magicrq <= '0';
			end if;
			
			if (A(15) or A(14)) = '1' then	-- dos off
				if BT_MAGIC = '0' then
					magicrq <= '1';
				else
					betasel <= '1';
				end if;
			end if;	
		end if;
	end if;
end process;

NMI <= '0' when magicrq = '1' else 'Z';
A15ROM <= '0' when betasel = '0' else 'Z';

-- I/O port 
iowr <= IORQ or WR or not M1;
process (iowr, RESET)
begin
	If RESET = '0' then
		rom48 <= '0';
	elsif rising_edge(iowr) then
		if betasel = '0' and (A(0) and A(1) and A(7)) = '1' then
			FD_DSEL0 <= D(0);
			FD_DSEL1 <= not D(0);
			FD_SIDE <= not D(4);
			VG_RES <= D(2);
			VG_HLT <= D(3);
		end if;
		if (A(1) or A(15)) = '0' then
			rom48 <= D(4);
		end if;
	end if;
end process;
 
 -- shift register
process (frq4)
begin
	if rising_edge(frq4) then
		if VG_WD = '1' then
			wrdreg(0) <= VG_SR and VG_TR43;
			wrdreg(1) <= not(VG_TR43 and (VG_SL or VG_SR));
			wrdreg(2) <= VG_SL and VG_TR43;
			wrdreg(3) <= '0';
		else
			wrdreg(3 downto 0) <= wrdreg(2 downto 0) & '0';
		end if;
	end if;
end process;

process (frq4)
begin
	if rising_edge(frq4) then
		ot_0 <= not(FD_RDD);
		ot_1 <= not ot_0;
	end if;
end process;
VG_RAWR <= ot_0 or ot_1;

 process (frq4)
begin
	if rising_edge(frq4) then
		if (ot_1 or ot_0) = '0' then
			cnt(3 downto 0) <= cnt(3) & "100";
		else
			cnt <= cnt + 1;
		end if;
	end if; 
end process;

VG_CLK <= cnt(1);
VG_RSLK <= cnt(3);
FD_WRD <= wrdreg(3);
VG_CS <= '0' when betasel = '0' and IORQ = '0' and A(1) = '1' and A(0) = '1' and A(7) = '0' else '1';
idrq <= '0' when betasel = '0' and IORQ = '0' and A(1) = '1' and A(0) = '1' and A(7) = '1' and WR = '1' else '1';

------------------ D_OUT ----------------------

process (rdh, idrq, sdstatus, sdread)
begin
	if rdh = '0' then				-- IDE data out
		D <= rdbf;
	elsif idrq = '0' then		-- FDC DRQ IRQ out to D6 D7
		D(6) <= VG_DRQ;
		D(7) <= VG_IRQ;
	elsif sdstatus = '0' then	-- port 77 SD status
		D <= (others => '0');
	elsif sdread = '0' then		-- port 57 SD read data
		D <= toCPU;
	else
		D <= (others => 'Z');
	end if;
end process;

------------------ IDE------------------------- 

ebl <= '0' when BT_IDE = '0' and betasel = '1' and A(1) = '0' and A(2) = '0' and M1 = '1' else '1';
iow <= '0' when A(0) = '0' and WR = '0' and ebl = '0' and IORQ = '0' else '1';
wrh <= '0' when A(0) = '1' and WR = '0' and ebl = '0' and IORQ = '0' else '1';		-- write most significant byte to buffer 
ior <= '0' when A(0) = '0' and RD = '0' and ebl = '0' and IORQ = '0' else '1';
rdh <= '0' when A(0) = '1' and RD = '0' and ebl = '0' and IORQ = '0' else '1';		-- read msb from buffer

BF_IOR <= ior;
BF_EBL <= ebl;
IDE_IOW <= iow;

IDE_HD(15 downto 8) <= wrbf(7 downto 0) when iow = '0' else (others => 'Z');

process (ior)
begin
	if rising_edge(ior) then
		rdbf(7 downto 0) <= IDE_HD(15 downto 8);
	end if;
end process;

process (wrh)
begin
	if falling_edge(wrh) then
		wrbf(7 downto 0) <= D(7 downto 0);
	end if;
end process;

----------------------SD CARD----------------- 

sdports <= '0' when A(7) = '0' and  A(4 downto 0) = "10111" and BT_SD = '0' and ebl = '1' and betasel = '1' else '1'; -- A4 = A4 & A6 (external logic)
port_57 <= sdports or A(5) or IORQ;
port_77 <= sdports or not A(5);
sdstatus <= port_77 or RD or IORQ;
sdread <= port_57 or RD;

process(iowr, RESET)
begin
	if RESET = '0' then
		SD_CS <= '1';
	elsif falling_edge(iowr) then
		if port_77 = '0' then	
			SD_CS <= D(1);
		end if;
	end if;
end process;

-- SPI

process(CLKIN, RESET)
begin
	if RESET = '0' then
		transState <= IDLE;
		TState <= (others => '0');
		fromSD <= (others => '1');
		toSD <= (others => '1');
		toCPU <= (others => '1');

	elsif falling_edge(CLKIN) then
		case transState is
			
		when IDLE =>
			if port_57 = '0' then
				transState <= SAMPLE;
			end if;
			
		when SAMPLE =>
				if RD = '1' then
					toSD <= D;
				end if;
				transState <= TRANSMIT;
			
		when TRANSMIT =>
				TState <= TState + 1;

            if TState < 15 then
					if TState(0) = '1' then
						toSD   <= toSD(6 downto 0) & '1';
						fromSD <= fromSD(6 downto 0) & SD_MISO;
					end if;
            else 
					if TState = 15 then 
						transState <= IDLE;
						toCPU <= fromSD(6 downto 0) & SD_MISO;
					end if;
             end if;
			when OTHERS =>
				null;
			end case;
		end if;

	SD_CLK <= TState(0);
	SD_MOSI <= toSD(7);
end process;

---------------------- RTC -----------------
RTC_DS <= '0' when A(3) = '0' and A(15 downto 12) = "1011" and RD = '0' and M1 = '1' and IORQ = '0' else '1';
RTC_RW <= '0' when A(3) = '0' and A(15 downto 12) = "1011" and WR = '0' and M1 = '1' and IORQ = '0' else '1';
RTC_AS <= '1' when A(3) = '0' and A(15 downto 12) = "1101" and WR = '0' and M1 = '1' and IORQ = '0' else '0';

process (iowr, RESET)
begin
	If RESET = '0' then
		RTC_CS <= '1';
	elsif falling_edge(iowr) then
		if A(3) = '0' and A(15 downto 12) = "1110" then
			RTC_CS <= not d(7);
		end if;
	end if;
end process;

-----------------------------------------------------------------------------------------------------------------------------------------------------------
end bdi;


