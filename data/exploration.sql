-- ============================================================================
-- DATA QUALITY NOTES
-- ============================================================================
-- 1. Overlapping tenancies: r_202 has t_010 (2025-04-01 to 2025-07-01) and
--    t_011 (2025-06-25 to 2025-12-01) overlapping for 7 days. Deduped by
--    counting each room once per day in daily_occupancy.
-- 2. Cancelled tenancy: t_015 (status = CANCELLED, r_302) overlaps with
--    active t_016. Excluded from occupancy via status != 'CANCELLED' filter.
--    Kept in staging/fd_tenancies for further analysis (cancellation rate).
-- 3. Soft-deleted property: p_003 (COVE JOO CHIAT) deleted 2025-12-01 but
--    lease runs until 2026-12-31. Rooms excluded from availability starting
--    Dec 2025. Tenancy t_016 (r_302) extends to 2026-01-31 but is ignored
--    because the room is no longer available.
-- 4. Soft-deleted room: r_201 deleted 2025-12-31 but tenancy t_009 runs to
--    2026-02-28. Room excluded from availability starting Jan 2026.
-- 5. Inconsistent date formats: deletedAt uses both "2025-12-01T00:00:00Z"
--    (ISO 8601) and "2025-12-31 00:00:00" (space-separated). DuckDB handles
--    both when casting to DATE.
-- ============================================================================


-- ============================================================================
-- RAW DATA LOAD
-- ============================================================================

SELECT * FROM read_json ("rooms.jsonl");
SELECT * FROM read_json ("properties.jsonl");
SELECT * FROM read_json ("tenancies.jsonl");

CREATE OR REPLACE TABLE rooms AS (
   SELECT * FROM read_json ("rooms.jsonl")
);

CREATE OR REPLACE TABLE properties AS (
   SELECT * FROM read_json ("properties.jsonl")
);

CREATE OR REPLACE TABLE tenancies AS (
   SELECT * FROM read_json ("tenancies.jsonl")
);


-- ============================================================================
-- STAGING LAYER
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS tht_cove_staging;

CREATE OR REPLACE TABLE tht_cove_staging.stg_properties AS (
   SELECT
       _id AS id,
       COALESCE (UPPER (name), 'UNKNOWN') AS property_name,
       COALESCE (UPPER (city), 'UNKNOWN') AS property_city,
       lease_start_date::DATE AS lease_start_date,
       lease_end_date::DATE AS lease_end_date,
       updatedAt::DATE AS updated_at,
       deletedAt::DATE AS deleted_at,
       CASE WHEN deletedAt IS NULL THEN FALSE ELSE TRUE END AS is_deleted
   FROM
       properties
);

CREATE OR REPLACE TABLE tht_cove_staging.stg_rooms AS (
   SELECT
       _id AS id,
       propertyId AS property_id,
       room_number,
       COALESCE (UPPER (type), 'UNKNOWN') AS room_type,
       updatedAt::DATE AS updated_at,
       deletedAt::DATE AS deleted_at,
       CASE WHEN deletedAt IS NULL THEN FALSE ELSE TRUE END AS is_deleted
   FROM
       rooms
);

CREATE OR REPLACE TABLE tht_cove_staging.stg_tenancies AS (
   SELECT
       _id AS id,
       roomId AS room_id,
       tenant_id,
       checkInDate::DATE AS check_in_date,
       checkOutDate::DATE AS check_out_date,
       COALESCE (UPPER (status), 'UNKNOWN') AS status,
       updatedAt::DATE AS updated_at
   FROM
       tenancies
);


-- ============================================================================
-- QC: OVERLAPPING TENANCIES DETECTION
-- ============================================================================

SELECT
   'OVERLAPPING TENANCIES' AS qc_check
   , a.room_id
   , a.id AS tenancy_a
   , a.check_in_date AS a_check_in
   , a.check_out_date AS a_check_out
   , b.id AS tenancy_b
   , b.check_in_date AS b_check_in
   , b.check_out_date AS b_check_out
   , DATEDIFF (
       'day', GREATEST (a.check_in_date, b.check_in_date),
       LEAST (a.check_out_date, b.check_out_date)
   ) AS overlap_days
FROM
   tht_cove_staging.stg_tenancies a
INNER JOIN
   tht_cove_staging.stg_tenancies b
   ON a.room_id = b.room_id
   AND a.id < b.id
   AND a.check_in_date < b.check_out_date
   AND b.check_in_date < a.check_out_date
ORDER BY
   a.room_id, a.check_in_date;


-- ============================================================================
-- MARTS
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS tht_cove_marts;

CREATE OR REPLACE TABLE tht_cove_marts.fd_tenancies AS (
   WITH rooms AS (
       SELECT
           id AS room_id,
           updated_at AS room_updated_at,
           * EXCLUDE (id, updated_at, is_deleted)
       FROM
           tht_cove_staging.stg_rooms
   ),

   properties AS (
       SELECT
           id AS property_id,
           updated_at AS property_updated_at,
           property_name,
           property_city,
           *
               EXCLUDE (
                   id,
                   property_name,
                   property_city,
                   updated_at,
                   is_deleted)
       FROM
           tht_cove_staging.stg_properties
   ),

   rooms_properties AS (
       SELECT
           room_id,
           room_updated_at,
           room_number,
           room_type,
           property_id,
           property_name,
           property_city,
           property_updated_at,
           lease_start_date,
           lease_end_date
       FROM
           rooms
       LEFT JOIN
           properties
           USING (property_id)
   ),

   tenancies AS (
       SELECT
           *
       FROM
           tht_cove_staging.stg_tenancies
   ),

   parsed_all AS (
       SELECT
           *
       FROM
           tenancies
       LEFT JOIN
           rooms_properties
           USING (room_id)
   )

   SELECT
       id,
       tenant_id,
       check_in_date,
       check_out_date,
       status,
       updated_at,
       room_id,
       room_updated_at,
       COALESCE (property_name, 'UNKNOWN') AS property_name,
       COALESCE (property_city, 'UNKNOWN') AS property_city
   FROM parsed_all
   ORDER BY updated_at, id
);

CREATE OR REPLACE TABLE tht_cove_marts.fm_occupancy_rate AS (
   WITH
   property_boundaries AS (
       SELECT
           MIN (lease_start_date) AS min_date,
           MAX (lease_end_date) AS max_date
       FROM
           tht_cove_staging.stg_properties
       WHERE
           is_deleted IS FALSE
   ),

   daily_spine AS (
       SELECT
           UNNEST (GENERATE_SERIES (
               (SELECT min_date FROM property_boundaries),
               (SELECT max_date FROM property_boundaries),
               INTERVAL 1 DAY
           )) AS date
   ),

   active_rooms AS (
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
           tht_cove_staging.stg_rooms r
       LEFT JOIN
           tht_cove_staging.stg_properties p
           ON r.property_id = p.id
   ),

   daily_availability AS (
       SELECT
           ds.date,
           ar.room_id,
           ar.property_id,
           ar.property_name
       FROM
           daily_spine ds,
           active_rooms ar
       WHERE
           TRUE
           AND ar.room_id IS NOT NULL
           AND ds.date BETWEEN ar.lease_start_date AND ar.lease_end_date
           AND (ar.room_deleted_at IS NULL OR ds.date < ar.room_deleted_at)
           AND (ar.property_deleted_at IS NULL OR ds.date < ar.property_deleted_at)
   ),

   daily_occupancy AS (
       SELECT DISTINCT
           ds.date, t.room_id
       FROM
           daily_spine ds,
           tht_cove_staging.stg_tenancies t
       WHERE
           TRUE
           AND t.room_id IS NOT NULL
           AND ds.date BETWEEN t.check_in_date AND t.check_out_date - INTERVAL 1 DAY
           AND t.status != 'CANCELLED'
   )

   SELECT
       da.property_name,
       DATE_TRUNC ('month', da.date) AS month,
       COUNT (*) AS available_room_days,
       COUNT (occ.room_id) AS occupied_room_days,
       ROUND (COUNT (occ.room_id)::DOUBLE / COUNT (*)::DOUBLE, 4) AS occupancy_rate
   FROM
       daily_availability da
   LEFT JOIN
       daily_occupancy occ
       ON da.date = occ.date
       AND da.room_id = occ.room_id
   GROUP BY
       da.property_name, DATE_TRUNC ('month', da.date)
   HAVING
       COUNT (*) > 0
   ORDER BY
       da.property_name, month
);

CREATE OR REPLACE TABLE tht_cove_marts.fsum_occupancy_rate AS (
   WITH
   property_boundaries AS (
       SELECT
           MIN (lease_start_date) AS min_date,
           MAX (lease_end_date) AS max_date
       FROM
           tht_cove_staging.stg_properties
       WHERE
           is_deleted IS FALSE
   ),

   daily_spine AS (
       SELECT
           UNNEST (GENERATE_SERIES (
               (SELECT min_date FROM property_boundaries),
               (SELECT max_date FROM property_boundaries),
               INTERVAL 1 DAY
           )) AS date
   ),

   active_rooms AS (
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
           tht_cove_staging.stg_rooms r
       LEFT JOIN
           tht_cove_staging.stg_properties p
           ON r.property_id = p.id
   ),

   daily_availability AS (
       SELECT
           ds.date,
           ar.room_id,
           ar.property_id,
           ar.property_name
       FROM
           daily_spine ds,
           active_rooms ar
       WHERE
           TRUE
           AND ar.room_id IS NOT NULL
           AND ds.date BETWEEN ar.lease_start_date AND ar.lease_end_date
           AND (ar.room_deleted_at IS NULL OR ds.date < ar.room_deleted_at)
           AND (ar.property_deleted_at IS NULL OR ds.date < ar.property_deleted_at)
   ),

   daily_occupancy AS (
       SELECT DISTINCT
           ds.date, t.room_id
       FROM
           daily_spine ds,
           tht_cove_staging.stg_tenancies t
       WHERE
           TRUE
           AND t.room_id IS NOT NULL
           AND ds.date BETWEEN t.check_in_date AND t.check_out_date - INTERVAL 1 DAY
           AND t.status != 'CANCELLED'
   )

   SELECT
       property_name,
       COUNT (*) AS available_room_days,
       COUNT (occ.room_id) AS occupied_room_days,
       ROUND (COUNT (occ.room_id)::DOUBLE / COUNT (*)::DOUBLE, 4) AS occupancy_rate
   FROM
       daily_availability
   LEFT JOIN
       daily_occupancy occ
       USING (date, room_id)
   GROUP BY
       1
   HAVING
       COUNT (*) > 0
   ORDER BY
       4 DESC, 1
);
