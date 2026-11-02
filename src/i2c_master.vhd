library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_master is
    generic (
        CLK_DIV : integer := 4  -- Дільник системної частоти для 1/4 періоду SCL
    );
    port (
        clk       : in    std_logic;                    -- Системний тактовий сигнал (50 МГц)
        rst       : in    std_logic;                    -- Асинхронне скидання (активний рівень '1')
        start     : in    std_logic;                    -- Імпульс запуску транзакції
        rw        : in    std_logic;                    -- Напрям обміну: '0' - запис (Write), '1' - читання (Read)
        addr      : in    std_logic_vector(6 downto 0); -- 7-бітна адреса веденого пристрою
        data_in   : in    std_logic_vector(7 downto 0); -- Байт для передачі веденому при записі
        scl       : inout std_logic;                    -- Тактова лінія шини I2C (open-drain)
        sda       : inout std_logic;                    -- Лінія даних шини I2C (двонаправлена, open-drain)
        busy      : out   std_logic;                    -- Ознака зайнятості модуля ('1' під час обміну)
        ack_error : out   std_logic;                    -- Прапорець відсутності ACK від веденого
        done      : out   std_logic;                    -- Імпульс завершення поточної транзакції
        data_out  : out   std_logic_vector(7 downto 0)  -- Прийнятий від веденого байт (при читанні)
    );
end entity i2c_master;

architecture rtl of i2c_master is

    -- Тип станів скінченного автомата (FSM)
    type state_type is (
        IDLE,        -- Стан спокою, шина вільна (SCL = 1, SDA = 1)
        START,       -- Формування умови START (спад SDA при SCL = 1)
        ADDR_TX,     -- Передача 7 бітів адреси веденого та біта R/W (старшим бітом уперед)
        ADDR_ACK,    -- Прийом підтвердження (ACK) адреси від веденого
        DATA_TX,     -- Передача 8 бітів даних веденому при операції запису
        DATA_ACK,    -- Прийом підтвердження (ACK) даних від веденого
        DATA_RX,     -- Прийом 8 бітів даних від веденого при операції читання
        MASTER_ACK,  -- Формування ведучим підтвердження NACK після читання байта
        STOP         -- Формування умови STOP (наростання SDA при SCL = 1)
    );

    signal state     : state_type := IDLE;
    signal phase     : integer range 0 to 3 := 0;
    signal clk_cnt   : integer range 0 to CLK_DIV - 1 := 0;
    signal bit_cnt   : integer range 0 to 7 := 7;
    
    -- Внутрішні регістри ліній (0 - активний низький рівень, 1 - високий опір Z)
    signal scl_reg   : std_logic := '1';
    signal sda_reg   : std_logic := '1';
    
    signal tx_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal ack_err_i : std_logic := '0';
    signal done_reg  : std_logic := '0';
    signal rw_reg    : std_logic := '0';

begin

    -- Виходи з відкритим стоком (Open-Drain):
    -- При значенні '0' лінія замикається на землю ('0').
    -- При значенні '1' лінія переводиться у Z (стан високого опору) і підтягується до '1' резистором.
    scl <= '0' when scl_reg = '0' else 'Z';
    sda <= '0' when sda_reg = '0' else 'Z';

    busy      <= '0' when state = IDLE else '1';
    ack_error <= ack_err_i;
    done      <= done_reg;
    data_out  <= rx_reg;

    process(clk, rst)
    begin
        if rst = '1' then
            state     <= IDLE;
            phase     <= 0;
            clk_cnt   <= 0;
            bit_cnt   <= 7;
            scl_reg   <= '1';
            sda_reg   <= '1';
            tx_reg    <= (others => '0');
            rx_reg    <= (others => '0');
            ack_err_i <= '0';
            done_reg  <= '0';
            rw_reg    <= '0';
        elsif rising_edge(clk) then
            done_reg <= '0'; -- імпульс завершення активний 1 такт

            case state is
                when IDLE =>
                    scl_reg <= '1';
                    sda_reg <= '1';
                    phase   <= 0;
                    clk_cnt <= 0;
                    bit_cnt <= 7;
                    if start = '1' then
                        rw_reg    <= rw;
                        tx_reg    <= addr & rw; -- Пакуємо 7 біт адреси та біт R/W
                        ack_err_i <= '0';
                        state     <= START;
                    end if;

                when START =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                scl_reg <= '1';
                                sda_reg <= '1';
                                phase   <= 1;
                            when 1 =>
                                -- Умова START: SDA спадає з '1' у '0' при високому рівні SCL
                                scl_reg <= '1';
                                sda_reg <= '0';
                                phase   <= 2;
                            when 2 =>
                                scl_reg <= '1';
                                sda_reg <= '0';
                                phase   <= 3;
                            when 3 =>
                                -- Перехід SCL у '0' для підготовки передачі першого біта
                                scl_reg <= '0';
                                sda_reg <= '0';
                                phase   <= 0;
                                bit_cnt <= 7;
                                state   <= ADDR_TX;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when ADDR_TX =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                -- SCL = 0: встановлюємо біт даних на лінію SDA
                                scl_reg <= '0';
                                sda_reg <= tx_reg(bit_cnt);
                                phase   <= 1;
                            when 1 =>
                                -- Наростаючий фронт SCL
                                scl_reg <= '1';
                                phase   <= 2;
                            when 2 =>
                                -- Утримання SCL = 1 (велений зчитує біт)
                                scl_reg <= '1';
                                phase   <= 3;
                            when 3 =>
                                -- Спадний фронт SCL
                                scl_reg <= '0';
                                phase   <= 0;
                                if bit_cnt > 0 then
                                    bit_cnt <= bit_cnt - 1;
                                else
                                    state   <= ADDR_ACK;
                                end if;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when ADDR_ACK =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                -- Відпускаємо SDA у стан 'Z', щоб ведений виставив ACK ('0')
                                scl_reg <= '0';
                                sda_reg <= '1';
                                phase   <= 1;
                            when 1 =>
                                scl_reg <= '1';
                                phase   <= 2;
                            when 2 =>
                                -- Стробування сигналу ACK від веденого
                                scl_reg <= '1';
                                if to_X01(sda) /= '0' then
                                    ack_err_i <= '1'; -- Фіксація помилки, якщо ведений не відповів
                                end if;
                                phase   <= 3;
                            when 3 =>
                                scl_reg <= '0';
                                phase   <= 0;
                                bit_cnt <= 7;
                                if ack_err_i = '1' or to_X01(sda) /= '0' then
                                    sda_reg <= '0';
                                    state   <= STOP;
                                elsif rw_reg = '0' then
                                    tx_reg <= data_in; -- Завантажуємо байт для передачі
                                    state  <= DATA_TX;
                                else
                                    state  <= DATA_RX; -- Переходимо до прийому байта
                                end if;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when DATA_TX =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                scl_reg <= '0';
                                sda_reg <= tx_reg(bit_cnt);
                                phase   <= 1;
                            when 1 =>
                                scl_reg <= '1';
                                phase   <= 2;
                            when 2 =>
                                scl_reg <= '1';
                                phase   <= 3;
                            when 3 =>
                                scl_reg <= '0';
                                phase   <= 0;
                                if bit_cnt > 0 then
                                    bit_cnt <= bit_cnt - 1;
                                else
                                    state   <= DATA_ACK;
                                end if;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when DATA_ACK =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                scl_reg <= '0';
                                sda_reg <= '1'; -- Відпускаємо SDA для ACK від веденого
                                phase   <= 1;
                            when 1 =>
                                scl_reg <= '1';
                                phase   <= 2;
                            when 2 =>
                                scl_reg <= '1';
                                if to_X01(sda) /= '0' then
                                    ack_err_i <= '1';
                                end if;
                                phase   <= 3;
                            when 3 =>
                                scl_reg <= '0';
                                sda_reg <= '0'; -- Готуємо низький рівень SDA перед STOP
                                phase   <= 0;
                                state   <= STOP;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when DATA_RX =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                scl_reg <= '0';
                                sda_reg <= '1'; -- Відпускаємо SDA для передачі від веденого
                                phase   <= 1;
                            when 1 =>
                                scl_reg <= '1';
                                phase   <= 2;
                            when 2 =>
                                scl_reg <= '1';
                                rx_reg(bit_cnt) <= to_X01(sda); -- Зчитуємо прийнятий біт
                                phase   <= 3;
                            when 3 =>
                                scl_reg <= '0';
                                phase   <= 0;
                                if bit_cnt > 0 then
                                    bit_cnt <= bit_cnt - 1;
                                else
                                    state   <= MASTER_ACK;
                                end if;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when MASTER_ACK =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                scl_reg <= '0';
                                sda_reg <= '1'; -- Ведучий відсилає NACK ('1') для завершення читання
                                phase   <= 1;
                            when 1 =>
                                scl_reg <= '1';
                                phase   <= 2;
                            when 2 =>
                                scl_reg <= '1';
                                phase   <= 3;
                            when 3 =>
                                scl_reg <= '0';
                                sda_reg <= '0'; -- Готуємо SDA = 0 для формування STOP
                                phase   <= 0;
                                state   <= STOP;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when STOP =>
                    if clk_cnt = CLK_DIV - 1 then
                        clk_cnt <= 0;
                        case phase is
                            when 0 =>
                                scl_reg <= '0';
                                sda_reg <= '0';
                                phase   <= 1;
                            when 1 =>
                                -- Наростаючий фронт SCL при низькому рівні SDA
                                scl_reg <= '1';
                                sda_reg <= '0';
                                phase   <= 2;
                            when 2 =>
                                -- Умова STOP: наростання SDA з '0' у '1' при високому рівні SCL
                                scl_reg <= '1';
                                sda_reg <= '1';
                                phase   <= 3;
                            when 3 =>
                                -- Завершення транзакції
                                scl_reg  <= '1';
                                sda_reg  <= '1';
                                done_reg <= '1';
                                phase    <= 0;
                                state    <= IDLE;
                        end case;
                    else
                        clk_cnt <= clk_cnt + 1;
                    end if;

                when others =>
                    state <= IDLE;
            end case;
        end if;
    end process;

end architecture rtl;
