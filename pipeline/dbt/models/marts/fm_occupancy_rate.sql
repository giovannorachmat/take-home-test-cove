-- noqa: disable=LT01,LT05

WITH active_rooms AS (
    SELECT
        r.id AS room_id,
        r.room_number,
        r.room_type,
        r.property_id,
        p.property_name,
        p.property_city,
        r.deleted_at AS room_deleted_at,
        p.deleted_at AS property_deleted_at,
        p.lease_start_date,
        p.lease_end_date
    FROM
    {{ ref('stg_rooms') }} r
    LEFT JOIN
    {{ ref('stg_properties') }} p
    ON r.property_id = p.id
),

daily_availability AS (
    SELECT
        d.date
        , ar.room_id
        , ar.property_id
        , ar.property_name
    FROM
    {{ ref('dim_date') }} d
    , active_rooms ar
    WHERE
    TRUE
    AND ar.room_id IS NOT NULL
    AND d.date BETWEEN ar.lease_start_date AND ar.lease_end_date
    AND (ar.room_deleted_at IS NULL OR d.date < ar.room_deleted_at)
    AND (ar.property_deleted_at IS NULL OR d.date < ar.property_deleted_at)
),

daily_occupancy AS (
    SELECT DISTINCT
        d.date, t.room_id
    FROM
    {{ ref('dim_date') }} d
    , {{ ref('stg_tenancies') }} t
    WHERE
    TRUE
    AND t.room_id IS NOT NULL
    AND d.date BETWEEN t.check_in_date AND date_sub (t.check_out_date, INTERVAL 1 day)
    AND t.status != 'CANCELLED'
)

SELECT
    da.property_name,
    date_trunc(da.date, month) AS month,
    count(*) AS available_room_days,
    count(occ.room_id) AS occupied_room_days,
    round(count(occ.room_id) / count(*), 4) AS occupancy_rate
FROM
    daily_availability da
LEFT JOIN
    daily_occupancy occ
    ON
        da.date = occ.date
        AND da.room_id = occ.room_id
GROUP BY
    da.property_name, date_trunc(da.date, month)
HAVING
    count(*) > 0
ORDER BY
    da.property_name, month
