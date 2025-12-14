import os
import io
import json
import uuid
import logging
from typing import Any, Dict

import boto3
import requests
import ydb

YDB_ENDPOINT = os.getenv("YDB_ENDPOINT")
YDB_DATABASE = os.getenv("YDB_DATABASE")

AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID")
AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY")

BUCKET_NAME = os.getenv("BUCKET_NAME")
ZONE = os.getenv("ZONE")

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def upload_to_bucket(filename: str, url: str) -> uuid.UUID:
    """
    Downloads a file from URL and uploads it to Object Storage.
    Returns generated UUID of the object.
    """
    s3_client = boto3.client(
        service_name="s3",
        endpoint_url="https://storage.yandexcloud.net",
        region_name=ZONE,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    )

    file_id = uuid.uuid4()
    object_key = f"docs/{file_id}"

    logger.info("Downloading file from %s", url)
    response = requests.get(url, stream=True, timeout=60)
    response.raise_for_status()

    buffer = io.BytesIO(response.content)

    logger.info("Uploading file %s to bucket %s", object_key, BUCKET_NAME)
    s3_client.upload_fileobj(
        buffer,
        BUCKET_NAME,
        object_key,
        ExtraArgs={
            "ContentType": response.headers.get(
                "Content-Type", "application/octet-stream"
            ),
            "ContentDisposition": f'attachment; filename="{filename}"',
        },
    )

    return file_id

def add_to_db(file_id: uuid.UUID, name: str, url: str) -> None:
    """
    Saves document metadata to YDB.
    """
    driver = ydb.Driver(
        endpoint=YDB_ENDPOINT,
        database=YDB_DATABASE,
        credentials=ydb.iam.MetadataUrlCredentials(),
    )

    try:
        driver.wait(fail_fast=True, timeout=5)
        session = driver.table_client.session().create()

        query = """
        DECLARE $id AS Uuid;
        DECLARE $name AS Utf8;
        DECLARE $url AS Utf8;

        UPSERT INTO docs (id, name, url)
        VALUES ($id, $name, $url);
        """

        params = {
            "$id": file_id,
            "$name": name,
            "$url": url,
        }

        prepared_query = session.prepare(query)
        session.transaction().execute(
            prepared_query,
            params,
            commit_tx=True,
        )

        logger.info("Document %s saved to DB", file_id)

    except Exception:
        logger.exception("Failed to save document to DB")

    finally:
        driver.stop()


def handler(event: Dict[str, Any], context: Any) -> Dict[str, int]:
    """
    Cloud Function entrypoint.
    """
    for msg in event.get("messages", []):
        body_raw = msg["details"]["message"]["body"]
        body = json.loads(body_raw)

        name = body.get("name")
        url = body.get("url")

        if not name or not url:
            logger.warning("Invalid message body: %s", body)
            continue

        try:
            file_id = upload_to_bucket(name, url)
            add_to_db(file_id, name, url)

        except Exception:
            logger.exception("Failed to process message")

    return {"statusCode": 200}
