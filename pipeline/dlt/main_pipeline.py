import json
import os

import dlt


@dlt.resource(table_name="properties", write_disposition="replace")
def load_properties():
    path = os.path.join(os.path.dirname(__file__), "../..", "data", "properties.jsonl")
    with open(path) as f:
        for line in f:
            yield json.loads(line.strip())


@dlt.resource(table_name="rooms", write_disposition="replace")
def load_rooms():
    path = os.path.join(os.path.dirname(__file__), "../..", "data", "rooms.jsonl")
    with open(path) as f:
        for line in f:
            yield json.loads(line.strip())


@dlt.resource(table_name="tenancies", write_disposition="replace")
def load_tenancies():
    path = os.path.join(os.path.dirname(__file__), "../..", "data", "tenancies.jsonl")
    with open(path) as f:
        for line in f:
            yield json.loads(line.strip())


if __name__ == "__main__":
    os.chdir(os.path.dirname(__file__))

    pipeline = dlt.pipeline(
        pipeline_name="cove_raw",
        destination="bigquery",
        dataset_name="tht_cove_raw",
    )
    pipeline.run([load_properties, load_rooms, load_tenancies])
    print("Done.")
