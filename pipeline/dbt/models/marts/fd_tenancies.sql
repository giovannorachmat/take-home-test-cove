with rooms as (
    select
        id as room_id
        , updated_at as room_updated_at
        , * except (id, updated_at, is_deleted)
    from
        {{ ref('stg_rooms') }}
)

, properties as (
    select
        id as property_id
        , updated_at as property_updated_at
        , property_name
        , property_city
        , * except (id,
        property_name,
        property_city,
        updated_at,
        is_deleted)
    from
        {{ ref('stg_properties') }}
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
        {{ ref('stg_tenancies') }}
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
