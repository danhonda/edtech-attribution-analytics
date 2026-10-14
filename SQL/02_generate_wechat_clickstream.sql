/*
================================================================================
SCRIPT: 02_generate_wechat_clickstream.sql
PROJECT: Cross-Channel EdTech Marketing & Product Attribution Model
ENGINE: DuckDB
INPUT: video_publishing_log.csv
OUTPUT: wechat_event_log.csv
PURPOSE:
    Simulates high-granularity WeChat Mini Program clickstream event logs 
    (~12,000+ rows) covering page_views, scroll milestones, add_to_cart, 
    cart_abandonment, and purchase_success transactions across the 180-day window.
================================================================================
*/

COPY (
    WITH RECURSIVE
    dates AS (
        SELECT DATE '2026-01-01' + range::INTEGER AS log_date
        FROM range(0, 180)
    ),
    -- Daily user volume driven by active publishing windows and content archetypes
    daily_traffic AS (
        SELECT 
            d.log_date,
            COALESCE(SUM(
                CASE 
                    WHEN v.topic_archetype = 'Pure Education' 
                         AND d.log_date BETWEEN v.publish_date AND v.publish_date + 6 
                    THEN 35
                    WHEN v.topic_archetype = 'Social Experiment' 
                         AND d.log_date BETWEEN v.publish_date AND v.publish_date + 2 
                    THEN 75
                    WHEN v.topic_archetype = 'Current Events' 
                         AND d.log_date BETWEEN v.publish_date AND v.publish_date + 3 
                    THEN 25
                    WHEN v.topic_archetype = 'American Culture' 
                         AND d.log_date BETWEEN v.publish_date AND v.publish_date + 3 
                    THEN 20
                    ELSE 8 -- Organic baseline traffic
                END
            ), 8) AS daily_users,
            MAX(COALESCE(v.topic_archetype, 'Organic Baseline')) AS active_archetype
        FROM dates d
        LEFT JOIN 'C:/Users/danho/OneDrive/Desktop/Project 3/video_publishing_log.csv' v 
            ON d.log_date BETWEEN v.publish_date AND v.publish_date + 6
        GROUP BY d.log_date
    ),
    -- Expand into individual user sessions
    user_sessions AS (
        SELECT 
            dt.log_date,
            'USR_' || LPAD(ROW_NUMBER() OVER ()::VARCHAR, 6, '0') AS user_id,
            'SESS_' || LPAD(ROW_NUMBER() OVER ()::VARCHAR, 6, '0') AS session_id,
            dt.active_archetype,
            dt.log_date::TIMESTAMP + (INTERVAL '1 second' * CAST(random() * 86300 AS INT)) AS session_start_ts,
            -- Revisit count (users returning multiple times)
            CASE 
                WHEN dt.active_archetype = 'Pure Education' AND random() < 0.40 THEN CAST(2 + (random() * 3) AS INT)
                WHEN dt.active_archetype = 'Social Experiment' AND random() < 0.10 THEN CAST(2 + (random() * 2) AS INT)
                ELSE 1 
            END AS visit_count,
            -- Maximum scroll depth reached
            CASE 
                WHEN dt.active_archetype = 'Pure Education' THEN CAST(60 + (random() * 40) AS INT)
                WHEN dt.active_archetype = 'Social Experiment' THEN CAST(20 + (random() * 35) AS INT)
                ELSE CAST(35 + (random() * 45) AS INT)
            END AS max_scroll_pct,
            random() AS intent_rand
        FROM daily_traffic dt
        CROSS JOIN range(1, 35) s
        WHERE s.range <= dt.daily_users
    ),
    -- Expand sessions into discrete behavioral events
    events_raw AS (
        -- Step 1: Page Landing
        SELECT 
            session_id,
            user_id,
            session_start_ts AS event_timestamp,
            'page_view' AS event_name,
            0 AS scroll_depth_pct,
            visit_count,
            active_archetype
        FROM user_sessions

        UNION ALL

        -- Step 2: Content Engagement / Scroll
        SELECT 
            session_id,
            user_id,
            session_start_ts + INTERVAL '18 seconds' AS event_timestamp,
            'scroll_milestone' AS event_name,
            max_scroll_pct AS scroll_depth_pct,
            visit_count,
            active_archetype
        FROM user_sessions
        WHERE max_scroll_pct >= 25

        UNION ALL

        -- Step 3: High Purchase Intent (Add to Cart)
        SELECT 
            session_id,
            user_id,
            session_start_ts + INTERVAL '45 seconds' AS event_timestamp,
            'add_to_cart' AS event_name,
            max_scroll_pct AS scroll_depth_pct,
            visit_count,
            active_archetype
        FROM user_sessions
        WHERE 
            (active_archetype = 'Pure Education' AND intent_rand < 0.50)
            OR (active_archetype = 'Current Events' AND intent_rand < 0.30)
            OR (active_archetype = 'American Culture' AND intent_rand < 0.25)
            OR (active_archetype = 'Social Experiment' AND intent_rand < 0.12)
            OR (active_archetype = 'Organic Baseline' AND intent_rand < 0.20)

        UNION ALL

        -- Step 4: Drop-off Friction (Cart Abandonment)
        SELECT 
            session_id,
            user_id,
            session_start_ts + INTERVAL '90 seconds' AS event_timestamp,
            'abandon_cart' AS event_name,
            max_scroll_pct AS scroll_depth_pct,
            visit_count,
            active_archetype
        FROM user_sessions
        WHERE 
            ((active_archetype = 'Pure Education' AND intent_rand >= 0.20 AND intent_rand < 0.50))
            OR ((active_archetype = 'Social Experiment' AND intent_rand >= 0.02 AND intent_rand < 0.12))
            OR ((active_archetype = 'Current Events' AND intent_rand >= 0.12 AND intent_rand < 0.30))
            OR ((active_archetype = 'American Culture' AND intent_rand >= 0.10 AND intent_rand < 0.25))

        UNION ALL

        -- Step 5: Completed Transaction via WeChat Pay (299 CNY)
        SELECT 
            session_id,
            user_id,
            session_start_ts + INTERVAL '115 seconds' AS event_timestamp,
            'purchase_success' AS event_name,
            100 AS scroll_depth_pct,
            visit_count,
            active_archetype
        FROM user_sessions
        WHERE 
            (active_archetype = 'Pure Education' AND intent_rand < 0.20)
            OR (active_archetype = 'Current Events' AND intent_rand < 0.12)
            OR (active_archetype = 'American Culture' AND intent_rand < 0.10)
            OR (active_archetype = 'Social Experiment' AND intent_rand < 0.02)
    )
    SELECT 
        'EVT_' || LPAD(ROW_NUMBER() OVER (ORDER BY event_timestamp)::VARCHAR, 7, '0') AS event_id,
        session_id,
        user_id,
        event_timestamp,
        event_name,
        scroll_depth_pct,
        visit_count,
        active_archetype,
        CASE WHEN event_name = 'purchase_success' THEN 299 ELSE 0 END AS order_amount_cny
    FROM events_raw
    ORDER BY event_timestamp
) TO 'C:/Users/danho/OneDrive/Desktop/Project 3/wechat_event_log.csv' (HEADER, DELIMITER ',');