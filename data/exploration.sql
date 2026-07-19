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

select * from read_json("rooms.jsonl");
select * from read_json("properties.jsonl");
select * from read_json("tenancies.jsonl");

create or replace table rooms as (
    select * from read_json("rooms.jsonl")
);

create or replace table properties as (
    select * from read_json("properties.jsonl")
);

create or replace table tenancies as (
    select * from read_json("tenancies.jsonl")
);


-- ============================================================================
-- STAGING LAYER
-- ============================================================================

create schema if not exists tht_cove_staging;

create or replace table tht_cove_staging.stg_properties as (
    select
        _id as id
        , * exclude (_id,
        updatedAt,
        deletedAt,
        name,
        city,
        lease_start_date,
        lease_end_date)
        , coalesce (upper (name), 'UNKNOWN') as property_name
        , coalesce (upper (city), 'UNKNOWN') as property_city
        , lease_start_date::date as lease_start_date
        , lease_end_date::date as lease_end_date
        , updatedAt::date as updated_at
        , deletedAt::date as deleted_at
        , case when deletedAt is null then false else true end as is_deleted
    from
        properties
);

create or replace table tht_cove_staging.stg_rooms as (
    select
        _id as id
        , propertyid as property_id
        , coalesce(upper(type), 'UNKNOWN') as room_type
        , * exclude (_id, propertyId, updatedAt, deletedAt, type)
        , updatedAt::date as updated_at
        , deletedAt::date as deleted_at
        , case when deletedAt is null then false else true end as is_deleted
    from
        rooms
);

create or replace table tht_cove_staging.stg_tenancies as (
    select
        _id as id
        , roomid as room_id
        , checkindate::date as check_in_date
        , checkoutdate::date as check_out_date
        , coalesce(upper(status), 'UNKNOWN') as status
        , * exclude (_id, checkInDate, roomId, checkOutDate, updatedAt, status)
        , updatedAt::date as updated_at
    from
        tenancies
);


-- ============================================================================
-- QC: OVERLAPPING TENANCIES DETECTION
-- ============================================================================

select
    'OVERLAPPING TENANCIES' as qc_check
    , a.room_id
    , a.id as tenancy_a
    , a.check_in_date as a_check_in
    , a.check_out_date as a_check_out
    , b.id as tenancy_b
    , b.check_in_date as b_check_in
    , b.check_out_date as b_check_out
    , datediff(
        'day', greatest(a.check_in_date, b.check_in_date),
        least(a.check_out_date, b.check_out_date)
    ) as overlap_days
from
    tht_cove_staging.stg_tenancies a
inner join
    tht_cove_staging.stg_tenancies b
    on
        a.room_id = b.room_id
        and a.id < b.id
        and a.check_in_date < b.check_out_date
        and b.check_in_date < a.check_out_date
order by
    a.room_id, a.check_in_date;


-- ============================================================================
-- MARTS
-- ============================================================================

create schema if not exists tht_cove_marts;

-- Denormalized tenancy view (kept for debugging / reference)
create or replace table tht_cove_marts.fd_tenancies as (
    with rooms as (
        select
            id as room_id
            , updated_at as room_updated_at
            , * exclude (id, updated_at, is_deleted)
        from
            tht_cove_staging.stg_rooms
    )

    , properties as (
        select
            id as property_id
            , updated_at as property_updated_at
            , property_name
            , property_city
            , * exclude (id,
            property_name,
            property_city,
            updated_at,
            is_deleted)
        from
            tht_cove_staging.stg_properties
    )

    , rooms_properties as (
        select
            room_id
            , room_updated_at
            , room_number
            , room_type
            , property_id
            , property_name
            , property_city
            , property_updated_at
            , lease_start_date
            , lease_end_date
        from
            rooms
        left join
            properties
            using (property_id)
    )

    , tenancies as (
        select
            *
        from
            tht_cove_staging.stg_tenancies
    )

    , parsed_all as (
        select
            *
        from
            tenancies
        left join
            rooms_properties
            using (room_id)
    )

    select
        id
        , tenant_id
        , check_in_date
        , check_out_date
        , status
        , updated_at
        , room_id
        , room_updated_at
        , coalesce(property_name, 'UNKNOWN') as property_name
        , coalesce(property_city, 'UNKNOWN') as property_city
    from parsed_all
    order by updated_at, id
);

-- Monthly occupancy rate by property
create or replace table tht_cove_marts.fm_occupancy_rate as (
    with
    property_boundaries as (
        select
            min(lease_start_date) as min_date
            , max(lease_end_date) as max_date
        from
            tht_cove_staging.stg_properties
        where
            is_deleted is false
    )

    , daily_spine as (
        select
            unnest(generate_series(
                (select min_date from property_boundaries),
                (select max_date from property_boundaries),
                interval 1 day
            )) as date
    )

    , active_rooms as (
        select
            r.id as room_id
            , r.room_number
            , r.room_type
            , r.property_id
            , p.property_name
            , p.property_city
            , r.deleted_at as room_deleted_at
            , p.deleted_at as property_deleted_at
            , p.lease_start_date
            , p.lease_end_date
        from
            tht_cove_staging.stg_rooms r
        inner join
            tht_cove_staging.stg_properties p
            on r.property_id = p.id
    )

    , daily_availability as (
        select
            ds.date
            , ar.room_id
            , ar.property_id
            , ar.property_name
        from
            daily_spine ds
        cross join
            active_rooms ar
        where
            ds.date >= ar.lease_start_date
            and ds.date <= ar.lease_end_date
            and (ar.room_deleted_at is null or ds.date < ar.room_deleted_at)
            and (
                ar.property_deleted_at is null
                or ds.date < ar.property_deleted_at
            )
    )

    , daily_occupancy as (
        select distinct
            ds.date
            , t.room_id
        from
            (select date from daily_spine) ds
        inner join
            tht_cove_staging.stg_tenancies t
            on
                t.check_in_date <= ds.date
                and ds.date < t.check_out_date
        where
            t.status != 'CANCELLED'
    )

    select
        da.property_name
        , date_trunc('month', da.date) as month
        , count(*) as available_room_days
        , count(occ.room_id) as occupied_room_days
        , round(count(occ.room_id)::double / count(*)::double, 4)
            as occupancy_rate
    from
        daily_availability da
    left join
        daily_occupancy occ
        on
            da.date = occ.date
            and da.room_id = occ.room_id
    group by
        da.property_name
        , date_trunc('month', da.date)
    having
        count(*) > 0
    order by
        da.property_name
        , month
);
