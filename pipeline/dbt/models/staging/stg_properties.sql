select
    _id as id
    , coalesce(upper(name), 'UNKNOWN') as property_name
    , coalesce(upper(city), 'UNKNOWN') as property_city
    , safe_cast(lease_start_date as date) as lease_start_date
    , safe_cast(lease_end_date as date) as lease_end_date
    , safe_cast(updated_at as date) as updated_at
    , safe_cast(deleted_at as date) as deleted_at
    , case when deleted_at is null then false else true end as is_deleted
from
    {{ source('raw', 'properties') }}
