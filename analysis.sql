-- ============================================================
-- Flop Club — SQL-запросы для анализа (PostgreSQL, схема import_schema.sql)
-- Каждый запрос привязан к конкретному бизнес-вопросу.
-- ============================================================


-- ============================================================
-- 0. DATA QUALITY — проверить до всего остального
-- ============================================================

-- Доля регистраций без finish_place
SELECT round(100.0 * count(*) FILTER (WHERE finish_place IS NULL) / count(*), 1)
       AS pct_missing_finish_place
FROM registrations;

-- Покрытие таблицы knockouts (ожидаем почти пустую таблицу — не строить на ней метрики)
SELECT count(*) AS knockout_rows,
       count(DISTINCT tournament_id) AS tournaments_covered
FROM knockouts;

-- Последняя дата турнира — чтобы понимать, обрублен ли текущий месяц
SELECT max(starts_at) AS last_tournament_date FROM tournaments;


-- ============================================================
-- 1. РОСТ И ПОСЕЩАЕМОСТЬ
-- Вопрос: растут ли число турниров и посадка от месяца к месяцу?
-- ============================================================

SELECT
    date_trunc('month', t.starts_at)::date AS month,
    count(DISTINCT t.id) AS tournaments,
    count(r.registration_id) FILTER (WHERE r.status = 'ACTIVE') AS active_entries,
    round(
        count(r.registration_id) FILTER (WHERE r.status = 'ACTIVE')::numeric
        / nullif(count(DISTINCT t.id), 0), 1
    ) AS avg_entries_per_tournament
FROM tournaments t
JOIN registrations r ON r.tournament_id = t.id
WHERE t.status = 'FINISHED'
GROUP BY 1
ORDER BY 1;
-- Внимание: последний месяц в выгрузке может быть неполным — не сравнивай его
-- с полными месяцами без нормализации по числу дней/турниров.


-- ============================================================
-- 2. УДЕРЖАНИЕ И ОТТОК
-- Вопрос: какая доля игроков сыграла один раз и не вернулась?
-- ============================================================

SELECT
    count(*) AS total_players,
    count(*) FILTER (WHERE tournaments_played = 0) AS zero_played,
    count(*) FILTER (WHERE tournaments_played = 1) AS played_once,
    round(100.0 * count(*) FILTER (WHERE tournaments_played <= 1) / count(*), 1) AS pct_churned
FROM players;

-- Парето: какую долю посещений даёт топ-10% игроков по активности
WITH ranked AS (
    SELECT player_id,
           tournaments_played,
           ntile(10) OVER (ORDER BY tournaments_played DESC) AS decile
    FROM players
)
SELECT
    decile,
    sum(tournaments_played) AS entries_in_decile,
    round(100.0 * sum(tournaments_played) / sum(sum(tournaments_played)) OVER (), 1) AS pct_of_total
FROM ranked
GROUP BY decile
ORDER BY decile;

-- Когортное удержание: % игроков когорты месяца X, вернувшихся в месяц X+N
WITH first_month AS (
    SELECT r.player_id,
           min(date_trunc('month', t.starts_at)) AS cohort_month
    FROM registrations r
    JOIN tournaments t ON t.id = r.tournament_id
    WHERE r.status = 'ACTIVE'
    GROUP BY r.player_id
),
activity AS (
    SELECT DISTINCT r.player_id,
           date_trunc('month', t.starts_at) AS active_month
    FROM registrations r
    JOIN tournaments t ON t.id = r.tournament_id
    WHERE r.status = 'ACTIVE'
)
SELECT
    fm.cohort_month,
    (extract(year FROM a.active_month) * 12 + extract(month FROM a.active_month))
      - (extract(year FROM fm.cohort_month) * 12 + extract(month FROM fm.cohort_month)) AS month_offset,
    count(DISTINCT a.player_id) AS active_players
FROM first_month fm
JOIN activity a ON a.player_id = fm.player_id AND a.active_month >= fm.cohort_month
GROUP BY 1, 2
ORDER BY 1, 2;


-- ============================================================
-- 3. ЮНИТ-ЭКОНОМИКА ТУРНИРОВ
-- Вопрос: окупают ли сборы с игроков объявленные гарантии призовых?
-- ============================================================

WITH entry_costs AS (
    SELECT
        r.tournament_id,
        r.registration_id,
        CASE WHEN r.entry_number = 1 THEN t.buy_in ELSE t.re_entry END
            + r.add_on_count * t.add_on_price AS cost
    FROM registrations r
    JOIN tournaments t ON t.id = r.tournament_id
    WHERE r.status = 'ACTIVE'
),
collected AS (
    SELECT tournament_id, sum(cost) AS gross_collected
    FROM entry_costs
    GROUP BY tournament_id
)
SELECT
    t.id,
    t.title,
    t.profile,
    t.buy_in,
    c.gross_collected,
    t.prize_pool,
    t.prize_pool - c.gross_collected AS overlay
FROM tournaments t
JOIN collected c ON c.tournament_id = t.id
WHERE t.status = 'FINISHED'
ORDER BY overlay DESC;
-- overlay — рабочая гипотеза на основе цифр (что гарантию подкрывает сам клуб),
-- не подтверждённый факт бизнес-модели — проверь с владельцем клуба.
-- Важно: каждая регистрация стоит buy_in ИЛИ re_entry, никогда оба сразу —
-- бы легко случайно посчитать это дважды, группируя отдельно "все входы" и "повторные входы".


-- ============================================================
-- 3b. LTV-ПРОКСИ (REVENUE TO DATE) ПО ИГРОКАМ
-- Вопрос: сколько денег в среднем принёс клубу один игрок к текущему моменту?
-- Это НЕ прогнозный LTV — это накопленная выручка на игрока на сегодня.
-- Выигрыши не вычитаются: в rating_results нет надёжного денежного поля
-- (percent/points относятся к отдельному рейтинговому пулу очков) —
-- уточни у клуба, прежде чем называть это "чистым" LTV.
-- ============================================================

WITH entry_costs AS (
    SELECT
        r.player_id,
        CASE WHEN r.entry_number = 1 THEN t.buy_in ELSE t.re_entry END
            + r.add_on_count * t.add_on_price AS cost
    FROM registrations r
    JOIN tournaments t ON t.id = r.tournament_id
    WHERE r.status = 'ACTIVE'
)
SELECT
    player_id,
    sum(cost) AS revenue_to_date
FROM entry_costs
GROUP BY player_id
ORDER BY revenue_to_date DESC;

-- ARPU и медиана по всем игравшим игрокам
WITH entry_costs AS (
    SELECT
        r.player_id,
        CASE WHEN r.entry_number = 1 THEN t.buy_in ELSE t.re_entry END
            + r.add_on_count * t.add_on_price AS cost
    FROM registrations r
    JOIN tournaments t ON t.id = r.tournament_id
    WHERE r.status = 'ACTIVE'
),
per_player AS (
    SELECT player_id, sum(cost) AS revenue_to_date
    FROM entry_costs GROUP BY player_id
)
SELECT
    round(avg(revenue_to_date), 0) AS arpu,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY revenue_to_date) AS median_revenue,
    max(revenue_to_date) AS max_revenue
FROM per_player;


-- ============================================================
-- 4. ФОРМАТЫ ТУРНИРОВ (продукт)
-- Вопрос: какие форматы дают лучшую посадку?
-- ============================================================

SELECT
    t.profile,
    count(DISTINCT t.id) AS tournaments,
    round(avg(e.cnt), 1) AS avg_entries,
    round(avg(t.buy_in), 0) AS avg_buy_in,
    round(avg(e.cnt)::numeric / avg(t.max_participants) * 100, 1) AS avg_fill_rate_pct
FROM tournaments t
JOIN (
    SELECT tournament_id, count(*) AS cnt
    FROM registrations
    WHERE status = 'ACTIVE'
    GROUP BY tournament_id
) e ON e.tournament_id = t.id
WHERE t.status = 'FINISHED'
GROUP BY t.profile
ORDER BY avg_entries DESC;

-- Ценовая эластичность: корреляция бай-ина и посадки
SELECT corr(t.buy_in::float, e.cnt::float) AS corr_buyin_entries
FROM tournaments t
JOIN (
    SELECT tournament_id, count(*) AS cnt
    FROM registrations
    WHERE status = 'ACTIVE'
    GROUP BY tournament_id
) e ON e.tournament_id = t.id
WHERE t.status = 'FINISHED';


-- ============================================================
-- 5. ОПЕРАЦИОНКА
-- Вопрос: какая доля неявок и отмен?
-- ============================================================

SELECT
    round(100.0 * count(*) FILTER (WHERE status = 'CANCELLED') / count(*), 1) AS cancellation_rate_pct,
    round(
        100.0 * count(*) FILTER (WHERE status = 'ACTIVE' AND checked_in = 'f')
        / nullif(count(*) FILTER (WHERE status = 'ACTIVE'), 0), 1
    ) AS no_show_rate_pct,
    round(
        100.0 * count(*) FILTER (WHERE status = 'ACTIVE' AND entry_number > 1)
        / nullif(count(*) FILTER (WHERE status = 'ACTIVE'), 0), 1
    ) AS re_entry_rate_pct
FROM registrations;
