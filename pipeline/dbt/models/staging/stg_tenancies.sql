select
    _id as id
    , room_id
    , tenant_id
    , safe_cast(check_in_date as date) as check_in_date
    , safe_cast(check_out_date as date) as check_out_date
    , coalesce(upper(status), 'UNKNOWN') as status
    , safe_cast(updated_at as date) as updated_at
from
    {{ source('raw', 'tenancies') }}
