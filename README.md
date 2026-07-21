# Cove Senior Data Engineer — Take Home Test

## Approach

I loaded the raw JSONL into BigQuery with dlt (extract + load) and transformed it
with dbt (transform). Staging views clean up column names and types, then two mart
tables land in tht_cove_marts: fd_tenancies (every booking, including cancelled
ones — `fd_` stands for fact-daily, one row per tenancy) and fm_occupancy_rate
(monthly occupancy by property — `fm_` stands for fact-monthly, one row per
property per month).

The occupancy logic works at a daily grain: for each room on each calendar date,
I check whether it's available (within lease, not soft-deleted yet) and whether
it's occupied (covered by a non-cancelled tenancy). Overlapping bookings on the
same room are deduped by counting once per day. Then I aggregate to property ×
month.

I built the same pipeline locally in DuckDB first (data/exploration.sql) so you
can run it right on your machine — no cloud credentials needed.

## Check It Out Locally

```
# install dependencies
uv sync

# fire up DuckDB and run the full ELT pipeline
cd data
duckdb exploration.db ".read exploration.sql"

# peek at the occupancy rate
duckdb exploration.db \
  -box "SELECT * FROM tht_cove_marts.fm_occupancy_rate \
        ORDER BY property_name, month"

# or the full tenancy view, cancelled bookings included
duckdb exploration.db \
  -box "SELECT * FROM tht_cove_marts.fd_tenancies ORDER BY id"

# or explore everything in the browser
duckdb exploration.db -ui
```

The last one opens DuckDB's built-in web UI — a local browser tab where you can
run queries, browse schemas, and explore tables without leaving your seat.

## What Gets Created

| Table | Description |
|---|---|
| `tht_cove_raw.properties` | raw JSONL, loaded by dlt |
| `tht_cove_raw.rooms` | raw JSONL, loaded by dlt |
| `tht_cove_raw.tenancies` | raw JSONL, loaded by dlt |
| `tht_cove_staging.stg_properties` | cleaned columns + types |
| `tht_cove_staging.stg_rooms` | cleaned columns + types |
| `tht_cove_staging.stg_tenancies` | cleaned columns + types |
| `tht_cove_staging.dim_date` | one row per day, from earliest lease to latest |
| `tht_cove_marts.fd_tenancies` | every tenancy, denormalised (fact-daily) |
| `tht_cove_marts.fm_occupancy_rate` | monthly occupancy by property (fact-monthly) |
| `tht_cove_marts.fsum_occupancy_rate` | all-time occupancy by property (fact-summary) |

## Data Quality Notes

I found a few things worth flagging:

1. **Overlapping tenancies** — r_202 has t_010 and t_011 overlapping for 6 days
   in June 2025. The pipeline dedupes these by counting each room once per day,
   so the occupancy rate doesn't get inflated. But the data might need cleaning
   upstream.

2. **Cancelled tenancy** — t_015 is cancelled but its dates (July 1–15 2025)
   overlap with active t_016 on the same room (r_302). Cancelled bookings are
   kept in staging and fd_tenancies for further analysis but excluded from the
   occupancy rate.

3. **Soft-deleted property** — p_003 (Cove Joo Chiat) was soft-deleted on
   Dec 1 2025 but its lease runs until Dec 2026. The pipeline stops counting
   room availability from the deletion date onward, so Dec 2025 and later show
   nothing for that property.

4. **Soft-deleted room** — r_201 was soft-deleted on Dec 31 2025 but has a
   tenancy (t_009) running until Feb 2026. The room disappears from availability
   in January 2026, so the tail end of that booking is excluded.

5. **Inconsistent date formats** — the source uses both ISO-8601
   (2025-12-01T00:00:00Z) and space-separated (2025-12-31 00:00:00). Both cast
   fine to DATE.

## Project Layout

```
data/
  properties.jsonl, rooms.jsonl, tenancies.jsonl     source data
  exploration.sql                                    DuckDB pipeline
  exploration.db                                     DuckDB output

pipeline/
  dlt/
    main_pipeline.py                                 dlt loader
    .dlt/config.toml, secrets.toml                   pipeline config
  dbt/
    models/staging/                                  stg_*.sql, dim_date.sql
    models/marts/                                    fd_tenancies, fm_occupancy_rate, fsum_occupancy_rate
    dbt_project.yml, profiles.yml                    dbt config
```

## Screenshots

### BigQuery Datasets
![](images/bigquery%20datasets.png)

### Looker Studio
![](images/datastudio%20dashboard.png)

### Raw Tables
![](images/raw%20properties.png)
![](images/raw%20rooms.png)
![](images/raw%20tenancies.png)

### Staging Views
![](images/staging%20view%20stg_properties.png)
![](images/staging%20view%20stg_rooms.png)
![](images/staging%20view%20stg_tenancies.png)

### Datamart Tables
![](images/datamart%20fd_tenancies.png)
![](images/datamart%20fm_occupancy_rate.png)
![](images/datamart%20fsum_occupancy_rate.png)
