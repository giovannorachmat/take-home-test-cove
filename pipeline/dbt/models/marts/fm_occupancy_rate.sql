with
active_rooms as (
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
        {{ ref('stg_rooms') }} r
    inner join
        {{ ref('stg_properties') }} p
        on r.property_id = p.id
)

, daily_availability as (
    select
        d.date
        , ar.room_id
        , ar.property_id
        , ar.property_name
    from
        {{ ref('dim_date') }} d
    left join
        active_rooms ar
        on
            d.date between ar.lease_start_date and ar.lease_end_date
            and (ar.room_deleted_at is null or d.date < ar.room_deleted_at)
            and (
                ar.property_deleted_at is null
                or d.date < ar.property_deleted_at
            )
    where
        ar.room_id is not null
)

, daily_occupancy as (
    select distinct
        d.date
        , t.room_id
    from
        {{ ref('dim_date') }} d
    left join
        {{ ref('stg_tenancies') }} t
        on
            d.date between t.check_in_date
            and date_sub(t.check_out_date, interval 1 day)
            and t.status != 'CANCELLED'
    where
        t.room_id is not null
)

select
    da.property_name
    , date_trunc(da.date, month) as month
    , count(*) as available_room_days
    , count(occ.room_id) as occupied_room_days
    , round(count(occ.room_id) / count(*), 4) as occupancy_rate
from
    daily_availability da
left join
    daily_occupancy occ
    on
        da.date = occ.date
        and da.room_id = occ.room_id
group by
    da.property_name
    , date_trunc(da.date, month)
having
    count(*) > 0
order by
    da.property_name
    , month
