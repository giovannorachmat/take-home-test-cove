{{ config(materialized='table') }}

select
    date
    , date_trunc(date, month) as month_start
    , format_date('%Y-%m', date) as month_label
from
    unnest(
        generate_date_array(
            (select min(lease_start_date) from {{ ref('stg_properties') }}),
            (select max(lease_end_date) from {{ ref('stg_properties') }}),
            interval 1 day
        )
    ) as date
