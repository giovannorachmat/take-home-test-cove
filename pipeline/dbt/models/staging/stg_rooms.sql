select
    _id as id
    , property_id
    , room_number
    , coalesce(upper(type), 'UNKNOWN') as room_type
    , safe_cast(updated_at as date) as updated_at
    , safe_cast(deleted_at as date) as deleted_at
    , case when deleted_at is null then false else true end as is_deleted
from
    {{ source('raw', 'rooms') }}
