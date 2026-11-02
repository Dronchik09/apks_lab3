library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master_tb is
end entity i2c_master_tb;

architecture sim of i2c_master_tb is

    constant CLK_PERIOD : time := 20 ns; -- 50 МГц системна частота

    signal clk       : std_logic := '0';
    signal rst       : std_logic := '0';
    signal start     : std_logic := '0';
    signal rw        : std_logic := '0';
    signal addr      : std_logic_vector(6 downto 0) := (others => '0');
    signal data_in   : std_logic_vector(7 downto 0) := (others => '0');
    signal scl       : std_logic := 'H';
    signal sda       : std_logic := 'H';
    signal busy      : std_logic;
    signal ack_error : std_logic;
    signal done      : std_logic;
    signal data_out  : std_logic_vector(7 downto 0);

    -- Сигнал для керування лінією SDA з боку тестової моделі веденого пристрою
    signal slave_sda : std_logic := 'Z';
    signal sim_done  : boolean := false;

begin

    -- Моделювання підтягуючих резисторів лінії I2C (Pull-up до '1' через стан 'H')
    scl <= 'H';
    sda <= 'H';
    sda <= slave_sda;

    -- Підключення тестованого модуля (UUT)
    uut: entity work.i2c_master
        generic map (
            CLK_DIV => 4
        )
        port map (
            clk       => clk,
            rst       => rst,
            start     => start,
            rw        => rw,
            addr      => addr,
            data_in   => data_in,
            scl       => scl,
            sda       => sda,
            busy      => busy,
            ack_error => ack_error,
            done      => done,
            data_out  => data_out
        );

    -- Генерація системного тактового сигналу 50 МГц
    clk_process : process
    begin
        while not sim_done loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- Поведінкова модель веденого пристрою (I2C Slave, адреса 0x38 = "0111000")
    slave_proc : process
        variable rx_byte : std_logic_vector(7 downto 0);
        variable tx_data : std_logic_vector(7 downto 0) := x"C3"; -- Байт, що ведений повертає при читанні
    begin
        slave_sda <= 'Z';
        -- Очікування умови START (спад SDA при високому SCL)
        wait until falling_edge(sda) and to_X01(scl) = '1';

        -- Прийом 8 бітів (7 бітів адреси + 1 біт R/W)
        for i in 7 downto 0 loop
            wait until rising_edge(scl);
            rx_byte(i) := to_X01(sda);
        end loop;

        -- Перевірка адреси веденого (0x38)
        if rx_byte(7 downto 1) = "0111000" then
            -- Формування ACK на байт адреси (біт 9)
            wait until falling_edge(scl);
            slave_sda <= '0';
            wait until falling_edge(scl);
            slave_sda <= 'Z';

            if rx_byte(0) = '0' then
                -- Транзакція запису: прийом 8 бітів даних від Master
                for i in 7 downto 0 loop
                    wait until rising_edge(scl);
                    rx_byte(i) := to_X01(sda);
                end loop;
                -- Формування ACK на байт даних
                wait until falling_edge(scl);
                slave_sda <= '0';
                wait until falling_edge(scl);
                slave_sda <= 'Z';
            else
                -- Транзакція читання: передача 8 бітів даних ведучому
                for i in 7 downto 0 loop
                    slave_sda <= tx_data(i);
                    wait until falling_edge(scl);
                end loop;
                slave_sda <= 'Z'; -- Звільнення шини для прийому NACK від ведучого
                wait until falling_edge(scl);
            end if;
        end if;
    end process;

    -- Процес формування тестових впливів (Stimulus Process)
    stim_process : process
    begin
        -- 1. Початкове асинхронне скидання
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 40 ns;

        -- 2. Тест 1: Операція запису (Write) байта 0xA5 за адресою 0x38
        -- Адреса 0x38 = "0111000", rw = '0' -> байт адреси = 0x70
        addr    <= "0111000"; -- 0x38
        rw      <= '0';       -- Write
        data_in <= x"A5";     -- Байт для запису
        start   <= '1';
        wait for CLK_PERIOD;
        start   <= '0';

        -- Очікування завершення транзакції запису
        wait until done = '1';
        wait for 200 ns;

        -- 3. Тест 2: Операція читання (Read) байта з адреси 0x38
        -- Очікується отримання байта 0xC3 від Slave
        addr  <= "0111000"; -- 0x38
        rw    <= '1';       -- Read
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';

        -- Очікування завершення транзакції читання
        wait until done = '1';
        wait for 200 ns;

        -- Перевірка результату прийому даних
        assert data_out = x"C3"
            report "Error: Expected data_out = 0xC3!" severity error;

        assert false
            report "Simulation completed successfully!" severity note;

        sim_done <= true; -- Коректне завершення симуляції
        wait;
    end process;

end architecture sim;
