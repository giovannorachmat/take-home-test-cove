-- noqa: disable=LT01,LT05,LT02

WITH rooms AS (
    SELECT
      id AS room_id,
      updated_at AS room_updated_at,
      * EXCEPT (id, updated_at, is_deleted)
    FROM
      {{ ref('stg_rooms') }}
  ),
  properties AS (
    SELECT
      id AS property_id,
      updated_at AS property_updated_at,
      property_name,
      property_city,
      *
        EXCEPT (
          id,
          property_name,
          property_city,
          updated_at,
          is_deleted)
    FROM
      {{ ref('stg_properties') }}
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
      {{ ref('stg_tenancies') }}
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
  coalesce(property_name, 'UNKNOWN') AS property_name,
  coalesce(property_city, 'UNKNOWN') AS property_city
FROM parsed_all
ORDER BY updated_at, id
