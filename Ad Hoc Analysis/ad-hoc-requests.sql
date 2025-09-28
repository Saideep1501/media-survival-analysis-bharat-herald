/*
	Business Request – 1: Monthly Circulation Drop Check
	Generate a report showing the top 3 months (2019–2024) where any city recorded the
	sharpest month-over-month decline in net_circulation.
*/
WITH MoM AS(
	SELECT f.city_id, d.city, f.month, f.year, f.net_circulation, 
    LAG(f.net_circulation) OVER (
            PARTITION BY f.city_id 
            ORDER BY f.year, f.month
        ) AS prev_month_circulation
    FROM fact_print_sales f
    JOIN dim_city d ON f.city_id = d.city_id
    WHERE f.year BETWEEN 2019 AND 2024
), 
CirculationDrop AS (
    SELECT 
        city_id,
        city,
        CONCAT(year, '-', LPAD(month,3,'0')) AS month_yyyymm,
        net_circulation,
        prev_month_circulation,
        (prev_month_circulation - net_circulation) AS drop_amount
    FROM MoM
    WHERE prev_month_circulation IS NOT NULL
)
SELECT city, month_yyyymm, drop_amount
FROM CirculationDrop
ORDER BY drop_amount DESC
LIMIT 3;


/*
	Business Request – 2: Yearly Revenue Concentration by Category
	Identify ad categories that contributed > 50% of total yearly ad revenue.
*/
WITH ad AS (
    SELECT 
        f.year,
        d.ad_category_id,
        d.standard_ad_category AS category_name,
        ROUND(SUM(f.revenue_in_INR),2) AS category_revenue
    FROM fact_ad_revenue f
    JOIN dim_ad_category d 
        ON f.ad_category = d.ad_category_id
    GROUP BY f.year, d.ad_category_id, d.standard_ad_category
),
yearly_total AS (
    SELECT
        year,
        ROUND(SUM(category_revenue),2) AS total_revenue_year
    FROM ad
    GROUP BY year
)
SELECT 
    a.year,
    a.category_name,
    a.category_revenue,
    y.total_revenue_year,
    ROUND((a.category_revenue / y.total_revenue_year) * 100,2) AS pct_of_year_total
FROM ad a
JOIN yearly_total y 
    ON a.year = y.year
WHERE (a.category_revenue / y.total_revenue_year) * 100 > 20
ORDER BY year, pct_of_year_total DESC;


/*
	Business Request – 3: 2024 Print Efficiency Leaderboard
	For 2024, rank cities by print efficiency = net_circulation / copies_printed. Return top 5.
*/
WITH pe AS(
	SELECT d.city, f.year, SUM(f.copies_sold + f.copies_returned) AS copies_printed, 
    SUM(f.net_circulation) AS net_circulation
    FROM fact_print_sales f
    JOIN dim_city d ON f.city_id = d.city_id
    GROUP BY d.city, f.year
),
leader AS (
	SELECT city, copies_printed, net_circulation, (net_circulation/copies_printed)*100 AS efficiency_ratio
    FROM pe
    WHERE year = 2024
)
SELECT city, copies_printed AS copies_printed_2024, net_circulation AS net_circulation_2024, 
efficiency_ratio AS efficiency_ratio_2024, 
ROW_NUMBER() OVER(ORDER BY efficiency_ratio DESC) AS efficiency_rank_2024
FROM leader
ORDER BY efficiency_rank_2024
LIMIT 5;


/*
	Business Request – 4 : Internet Readiness Growth (2021)
	For each city, compute the change in internet penetration from Q1-2021 to Q4-2021
	and identify the city with the highest improvement.
*/
 WITH Ip AS(
	SELECT d.city,
    SUM( CASE WHEN f.quarter = "2021-Q1" THEN f.internet_penetration ELSE 0 END) AS internet_rate_q1_2021, 
    SUM(CASE WHEN f.quarter = "2021-Q4" THEN f.internet_penetration ELSE 0 END) AS internet_rate_q4_2021
    FROM fact_city_readiness f
    JOIN dim_city d ON f.city_id = d.city_id
    WHERE f.quarter IN ("2021-Q1", "2021-Q4")
    GROUP BY d.city
 ) SELECT city, internet_rate_q1_2021, internet_rate_q4_2021, 
 ROUND(SUM(internet_rate_q4_2021-internet_rate_q1_2021),2) AS delta_internet_rate 
 FROM Ip
 GROUP BY city;
 
 
/*
	Business Request – 5: Consistent Multi-Year Decline (2019→2024)
	Find cities where both net_circulation and ad_revenue decreased every year from 2019
	through 2024 (strictly decreasing sequences).
*/ 
WITH print_data AS (
    SELECT
        d.city,
        f.edition_id,
        f.year,
        SUM(f.net_circulation) AS yearly_net_circulation
    FROM fact_print_sales f
    JOIN dim_city d ON f.city_id = d.city_id
    WHERE f.year BETWEEN 2019 AND 2024
    GROUP BY d.city, f.edition_id, f.year
),
ad_data AS (
    SELECT
        edition_id,
        year,
        SUM(revenue_in_INR) AS yearly_ad_revenue
    FROM fact_ad_revenue
    WHERE year BETWEEN 2019 AND 2024
    GROUP BY edition_id, year
),
combined_data AS (
    SELECT
        p.city,
        p.year,
        SUM(p.yearly_net_circulation) AS yearly_net_circulation,
        SUM(COALESCE(a.yearly_ad_revenue, 0)) AS yearly_ad_revenue
    FROM print_data p
    LEFT JOIN ad_data a 
        ON p.edition_id = a.edition_id AND p.year = a.year
    GROUP BY p.city, p.year
),
lagged AS (
    SELECT
        city,
        year,
        yearly_net_circulation,
        yearly_ad_revenue,
        LAG(yearly_net_circulation) OVER (PARTITION BY city ORDER BY year) AS prev_net_circulation,
        LAG(yearly_ad_revenue) OVER (PARTITION BY city ORDER BY year) AS prev_ad_revenue
    FROM combined_data
)
SELECT
    city AS city_name,
    year,
    yearly_net_circulation,
    yearly_ad_revenue,
    CASE 
        WHEN prev_net_circulation IS NOT NULL AND yearly_net_circulation < prev_net_circulation THEN 'Yes'
        ELSE 'No'
    END AS is_declining_print,
    CASE 
        WHEN prev_ad_revenue IS NOT NULL AND yearly_ad_revenue < prev_ad_revenue THEN 'Yes'
        ELSE 'No'
    END AS is_declining_ad_revenue,
    CASE 
        WHEN prev_net_circulation IS NOT NULL 
             AND yearly_net_circulation < prev_net_circulation
             AND yearly_ad_revenue < prev_ad_revenue THEN 'Yes'
        ELSE 'No'
    END AS is_declining_both
FROM lagged
ORDER BY city_name, year;


/*
	Business Request – 6 : 2021 Readiness vs Pilot Engagement Outlier
	In 2021, identify the city with the highest digital readiness score but among the bottom 3
	in digital pilot engagement.
	readiness_score = AVG(smartphone_rate, internet_rate, literacy_rate)
	“Bottom 3 engagement” uses the chosen engagement metric provided (e.g.,
	engagement_rate, active_users, or sessions).
*/ 

WITH readiness_data AS (
    SELECT
        d.city_id,
        d.city,
        f.year,
        ROUND(AVG((f.literacy_rate + f.smartphone_penetration + f.internet_penetration) / 3), 2) AS readiness_score
    FROM fact_city_readiness f
    JOIN dim_city d ON f.city_id = d.city_id
    WHERE f.year = 2021
    GROUP BY d.city_id, d.city, f.year
), 
engagement_data AS (
    SELECT 
        d.city_id, 
        d.city, 
        c.year, 
        ROUND(SUM(c.downloads_or_accesses) * 100.0 / NULLIF(SUM(c.users_reached), 0), 2) AS engagement_metric
    FROM fact_digital_pilot c
    JOIN dim_city d ON c.city_id = d.city_id
    WHERE c.year = 2021
    GROUP BY d.city_id, d.city, c.year
),
combined AS (
    SELECT 
        r.city_id,
        r.city AS city_name,
        r.readiness_score,
        e.engagement_metric
    FROM readiness_data r
    JOIN engagement_data e ON r.city_id = e.city_id
),
ranked AS (
    SELECT *,
        RANK() OVER (ORDER BY readiness_score DESC) AS readiness_rank_desc,
        RANK() OVER (ORDER BY engagement_metric ASC) AS engagement_rank_asc
    FROM combined
)
SELECT 
    city_name,
    readiness_score AS readiness_score_2021,
    engagement_metric AS engagement_metric_2021,
    readiness_rank_desc,
    engagement_rank_asc,
    CASE 
        WHEN engagement_rank_asc <= 3 THEN 'Yes'
        ELSE 'No'
    END AS is_outlier
FROM ranked
ORDER BY readiness_rank_desc;
 