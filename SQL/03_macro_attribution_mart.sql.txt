/*
================================================================================
SCRIPT: 03_macro_attribution_mart.sql
PROJECT: Cross-Channel EdTech Marketing & Product Attribution Model
ENGINE: DuckDB
INPUTS: video_publishing_log.csv, wechat_event_log.csv
OUTPUT: macro_attribution_summary.csv
PURPOSE:
    Central analytical mart connecting video publishing variables with downstream
    WeChat clickstream events across 7-day and 14-day attribution windows.
    Computes qualified target reach, estimated CTA exposure, cart abandonment,
    inquiry-to-purchase CVR, and revenue efficiency per 10k views.
================================================================================
*/

COPY (
    WITH campaign_windows AS (
        SELECT 
            v.video_id,
            v.platform,
            v.publish_date,
            v.topic_archetype,
            v.course_promoted,
            v.duration_sec,
            v.hook_duration_type,
            v.has_pattern_interrupt,
            v.cta1_timestamp_sec,
            v.cta2_timestamp_sec,
            v.impressions,
            v.ctr_pct,
            v.avg_retention_pct,
            v.views_7d,
            v.views_14d,
            v.sub_conversion_pct,
            v.pct_mainland_china,
            v.pct_target_expats_geo,
            v.pct_non_target_global_geo,

            -- Qualified target view volume (excludes algorithmic spillover in LATAM/Europe)
            CAST(v.views_14d * ((v.pct_mainland_china + v.pct_target_expats_geo) / 100.0) AS INT) AS qualified_target_views,

            -- Estimated audience reach surviving to CTA 1 (3-5 min) and CTA 2 (outro)
            CAST(v.views_14d * (v.avg_retention_pct / 100.0) * 1.15 AS INT) AS est_cta1_viewers,
            CAST(v.views_14d * (v.avg_retention_pct / 100.0) * (CASE WHEN v.has_pattern_interrupt THEN 0.65 ELSE 0.45 END) AS INT) AS est_cta2_viewers,

            -- 7-Day Window Aggregations from Clickstream
            COUNT(DISTINCT CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '7 days' 
                     AND e.event_name = 'page_view' 
                THEN e.session_id 
            END) AS sessions_7d,

            COUNT(DISTINCT CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '7 days' 
                     AND e.event_name = 'purchase_success' 
                THEN e.session_id 
            END) AS sales_7d,

            COALESCE(SUM(CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '7 days' 
                THEN e.order_amount_cny 
                ELSE 0 
            END), 0) AS rev_7d,

            -- 14-Day Window Aggregations from Clickstream
            COUNT(DISTINCT CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '14 days' 
                     AND e.event_name = 'page_view' 
                THEN e.session_id 
            END) AS sessions_14d,

            COUNT(DISTINCT CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '14 days' 
                     AND e.event_name = 'add_to_cart' 
                THEN e.session_id 
            END) AS cart_adds_14d,

            COUNT(DISTINCT CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '14 days' 
                     AND e.event_name = 'abandon_cart' 
                THEN e.session_id 
            END) AS cart_abandons_14d,

            COUNT(DISTINCT CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '14 days' 
                     AND e.event_name = 'purchase_success' 
                THEN e.session_id 
            END) AS sales_14d,

            COALESCE(SUM(CASE 
                WHEN e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '14 days' 
                THEN e.order_amount_cny 
                ELSE 0 
            END), 0) AS rev_14d

        FROM 'C:/Users/danho/OneDrive/Desktop/Project 3/video_publishing_log.csv' v
        LEFT JOIN 'C:/Users/danho/OneDrive/Desktop/Project 3/wechat_event_log.csv' e
            ON e.event_timestamp BETWEEN v.publish_date AND v.publish_date + INTERVAL '14 days'
        GROUP BY 
            v.video_id,
            v.platform,
            v.publish_date,
            v.topic_archetype,
            v.course_promoted,
            v.duration_sec,
            v.hook_duration_type,
            v.has_pattern_interrupt,
            v.cta1_timestamp_sec,
            v.cta2_timestamp_sec,
            v.impressions,
            v.ctr_pct,
            v.avg_retention_pct,
            v.views_7d,
            v.views_14d,
            v.sub_conversion_pct,
            v.pct_mainland_china,
            v.pct_target_expats_geo,
            v.pct_non_target_global_geo
    )
    SELECT 
        video_id,
        platform,
        publish_date,
        topic_archetype,
        course_promoted,
        duration_sec,
        hook_duration_type,
        has_pattern_interrupt,
        cta1_timestamp_sec,
        cta2_timestamp_sec,
        impressions,
        ctr_pct,
        avg_retention_pct,
        views_7d,
        views_14d,
        sub_conversion_pct,
        pct_mainland_china,
        pct_target_expats_geo,
        pct_non_target_global_geo,
        qualified_target_views,
        est_cta1_viewers,
        est_cta2_viewers,
        sessions_7d,
        sales_7d,
        rev_7d,
        sessions_14d,
        cart_adds_14d,
        cart_abandons_14d,
        sales_14d,
        rev_14d,
        -- Product Metric: Cart Abandonment Rate (%)
        ROUND((cart_abandons_14d * 100.0) / NULLIF(cart_adds_14d, 0), 2) AS cart_abandonment_rate_pct,
        -- Funnel Metric: Session-to-Paid Conversion Rate (%)
        ROUND((sales_14d * 100.0) / NULLIF(sessions_14d, 0), 2) AS session_to_purchase_cvr_pct,
        -- Executive Efficiency: Gross Revenue per 10k Total Views (CNY)
        ROUND((rev_14d * 10000.0) / NULLIF(views_14d, 0), 2) AS rev_per_10k_views_14d_cny,
        -- Audience Efficiency: Gross Revenue per 10k Qualified Views (CNY)
        ROUND((rev_14d * 10000.0) / NULLIF(qualified_target_views, 0), 2) AS rev_per_10k_target_views_cny
    FROM campaign_windows
    ORDER BY publish_date
) TO 'C:/Users/danho/OneDrive/Desktop/Project 3/macro_attribution_summary.csv' (HEADER, DELIMITER ',');